"""Simulasi HR & Talent (deterministik) untuk schema fnb: PII karyawan, kompensasi, absensi, payroll,
review kinerja, requisition dan lamaran kerja.

Setiap acak di-seed per entitas/tanggal (bukan per urutan), sehingga simulasi s.d. tanggal E selalu
menghasilkan histori yang sama untuk tanggal <= E. `sync()` membangun ulang "dunia HR" s.d. `end` lalu
meng-upsert: baris baru disisipkan, baris yang berubah (mis. lamaran yang maju tahap, karyawan resign)
diperbarui dan updated_at dinaikkan, baris yang sama persis tidak disentuh (ramah dlt incremental).

Event yang terjadi setelah `end` tidak terlihat: tahapan rekrutmen di masa depan = NULL / 'In Process',
karyawan yang belum mulai kerja belum dibuat, kenaikan gaji baru muncul setelah review dilakukan.
"""
import datetime as dt
import math
from collections import defaultdict

FEMALE = {"Siti", "Dewi", "Putri", "Ayu", "Nina", "Rina", "Maya", "Lestari", "Wulan", "Intan", "Sari", "Citra",
          "Anisa", "Fitri", "Mega", "Nadia", "Sinta", "Laras"}
NIK_PREFIX = {"FLG-01": "3171", "KIOSK-02": "3273", "CLOUD-03": "3174"}
SHIFT_START = {"Barista": (7, 13), "Cashier": (7, 13), "Cook": (9, 14), "Supervisor": (9, 9), "Outlet Manager": (9, 9)}


class HRSim:
    def __init__(self, cfg, rnd_for, local_dt, day_flags, first_names, last_names):
        self.cfg, self.hr = cfg, cfg["hr"]
        self.rnd_for, self.local_dt, self.day_flags = rnd_for, local_dt, day_flags
        self.first_names, self.last_names = first_names, last_names
        self.start = cfg["start_date"]
        self.closed = set(cfg["demand"]["closed_days"])

    # ------------------------------------------------------------------ util
    def pick(self, rnd, weights):
        r, acc = rnd.random() * sum(weights.values()), 0.0
        for k, w in weights.items():
            acc += w
            if r <= acc:
                return k
        return k

    def person(self, key, outlet, first=None, last=None):
        """Atribut PII sintetis yang stabil per orang."""
        rnd = self.rnd_for("hr", "person", key)
        first = first or rnd.choice(self.first_names)
        last = last or rnd.choice(self.last_names)
        gender = "F" if first in FEMALE else "M"
        birth = dt.date(1981, 1, 1) + dt.timedelta(days=rnd.randint(0, 365 * 25))
        dd = birth.day + (40 if gender == "F" else 0)
        nik = f"{NIK_PREFIX[outlet]}{rnd.randint(10, 99)}{dd:02d}{birth:%m%y}{rnd.randint(1, 9999):04d}"
        email = f"{first}.{last}{rnd.randint(1, 99)}@{self.hr['email_domain']}".lower()
        phone = f"0857{rnd.randint(10_000_000, 99_999_999)}"
        return {"full_name": f"{first} {last}", "phone_number": phone, "national_id": nik,
                "birth_date": birth, "gender": gender, "email": email}

    def ts(self, day, hour, minute=0):
        return self.local_dt(day, hour, minute)

    # ------------------------------------------------------------------ simulasi
    def run(self, core, end):
        """core: [{employee_id, outlet_id, full_name, phone_number, job_role, hired_date}] karyawan tetap di DB."""
        hr, pt = self.hr, self.hr["part_time"]
        out = defaultdict(list)
        emps = {}                                                   # employee_id -> dict
        for e in core:
            first, _, last = e["full_name"].partition(" ")
            p = self.person(e["employee_id"], e["outlet_id"], first, last or "Santoso")
            p.update(full_name=e["full_name"], phone_number=e["phone_number"])
            emps[e["employee_id"]] = dict(e, **p, employment_type="Full-time", hire_source="Initial",
                                          terminated_date=None, termination_reason=None)
        short = {o: c["short"] for o, c in self.cfg["outlets"].items()}
        seq = defaultdict(int)

        def new_pt(outlet, role, hired, source, person_key, person=None):
            seq[outlet] += 1
            eid = f"P{short[outlet]}{seq[outlet]:03d}"
            p = person or self.person(person_key, outlet)
            emps[eid] = dict(employee_id=eid, outlet_id=outlet, job_role=role, hired_date=hired, **p,
                             employment_type="Part-time", hire_source=source, terminated_date=None,
                             termination_reason=None)
            return eid

        for outlet, n in pt["headcount"].items():                  # crew awal (sebelum periode simulasi)
            for i in range(n):
                rnd = self.rnd_for("hr", "pt0", outlet, i)
                new_pt(outlet, self.pick(rnd, pt["roles"]), dt.date(2025, 6, rnd.randint(2, 28)),
                       self.pick(rnd, self.hr["recruitment"]["source_weights"]), ("pt0", outlet, i))

        pending, reqs, apps = [], [], []                            # pending: (start_date, outlet, role, src, req, person)
        day = self.start
        while day <= end:
            for item in sorted([p for p in pending if p[0] == day], key=lambda p: p[4]["requisition_id"]):
                start, outlet, role, src, req, person = item
                eid = new_pt(outlet, role, start, src, None, person)
                req["filled_date"], req["filled_by_employee_id"] = start, eid
                req["_hire_app"]["hired_employee_id"] = eid
            pending = [p for p in pending if p[0] != day]
            for eid in sorted(emps):
                e = emps[eid]
                if e["employment_type"] != "Part-time" or e["terminated_date"] or e["hired_date"] >= day:
                    continue
                monthly = pt["monthly_attrition"].get(e["hire_source"], pt["monthly_attrition"]["default"])
                if (day - e["hired_date"]).days <= pt["early_tenure_days"]:
                    monthly *= 2
                hazard = 1 - (1 - monthly) ** (1 / 30)
                rnd = self.rnd_for("hr", "attr", eid, day)
                if rnd.random() < hazard:
                    e["terminated_date"] = day
                    e["termination_reason"] = self.pick(rnd, pt["termination_reason"])
                    req, req_apps, hire = self.recruit(e, day, len([r for r in reqs if r["opened_date"] == day]))
                    reqs.append(req)
                    apps.extend(req_apps)
                    if hire:
                        pending.append(hire)
            day += dt.timedelta(days=1)

        # visibilitas per `end`: sembunyikan event setelah end
        end_ts = self.ts(end + dt.timedelta(days=1), 0)
        for a in apps:
            for col in ("screened_at", "interviewed_at", "offered_at", "decided_at"):
                if a[col] is not None and a[col] >= end_ts:
                    a[col] = None
            if a["decided_at"] is None:
                a["status"], a["hired_employee_id"] = "In Process", None
        out["employees"] = list(emps.values())
        out["job_requisitions"] = reqs
        out["job_applications"] = [a for a in apps if a["applied_at"] < end_ts]
        self.attendance(emps, end, out)
        self.reviews(emps, end, out)
        self.compensation(emps, end, out)
        self.payroll(emps, end, out)
        return out

    def recruit(self, leaver, opened, n_same_day):
        rc = self.hr["recruitment"]
        outlet, role = leaver["outlet_id"], leaver["job_role"]
        rid = f"REQ-{outlet}-{opened:%Y%m%d}-{n_same_day + 1}"
        rnd = self.rnd_for("hr", "req", rid)
        req = dict(requisition_id=rid, outlet_id=outlet, job_role=role, employment_type="Part-time",
                   reason="Replacement", replaces_employee_id=leaver["employee_id"], opened_date=opened,
                   filled_date=None, filled_by_employee_id=None)
        apps, passed = [], []
        for i in range(rnd.randint(*rc["applications_per_requisition"])):
            ar = self.rnd_for("hr", "app", rid, i)
            src = self.pick(ar, rc["source_weights"])
            applied = self.ts(opened + dt.timedelta(days=ar.randint(0, rc["application_window_days"])),
                              ar.randint(8, 21), ar.randint(0, 59))
            p = self.person(("cand", rid, i), outlet)
            a = dict(application_id=f"{rid}-A{i + 1:02d}", requisition_id=rid, candidate_name=p["full_name"],
                     candidate_phone=p["phone_number"], source=src, applied_at=applied, screened_at=None,
                     interviewed_at=None, offered_at=None, decided_at=None, status="Rejected",
                     hired_employee_id=None, _person=p)
            a["screened_at"] = applied + dt.timedelta(days=ar.randint(1, 3), hours=ar.randint(0, 6))
            if ar.random() < rc["withdraw_prob"]:
                a["status"], a["decided_at"] = "Withdrawn", a["screened_at"]
            elif ar.random() < rc["screen_pass"][src]:
                a["interviewed_at"] = a["screened_at"] + dt.timedelta(days=ar.randint(2, 5))
                if ar.random() < rc["interview_pass"][src]:
                    passed.append(a)
                else:
                    a["decided_at"] = a["interviewed_at"] + dt.timedelta(days=ar.randint(1, 2))
            else:
                a["decided_at"] = a["screened_at"]
            apps.append(a)
        if not passed:                                              # tidak ada yang lolos: tawarkan ke yang diinterview
            passed = [a for a in apps if a["interviewed_at"] is not None] or [a for a in apps if a["status"] != "Withdrawn"]
            for a in passed:
                if a["interviewed_at"] is None:
                    a["interviewed_at"] = a["screened_at"] + dt.timedelta(days=2)
        passed.sort(key=lambda a: a["interviewed_at"])
        hire = None
        offer_at = None
        for a in passed:
            ar = self.rnd_for("hr", "offer", a["application_id"])
            offer_at = max(offer_at or a["interviewed_at"], a["interviewed_at"]) + dt.timedelta(days=ar.randint(1, 3))
            if hire:                                                # posisi sudah terisi
                a["status"], a["decided_at"] = "Rejected", offer_at
                continue
            a["offered_at"] = offer_at
            a["decided_at"] = offer_at + dt.timedelta(days=ar.randint(0, 2))
            if ar.random() < self.hr["recruitment"]["offer_accept"][a["source"]] or a is passed[-1]:
                a["status"] = "Hired"
                start = a["decided_at"].date() + dt.timedelta(days=ar.randint(*rc["start_after_accept_days"]))
                req["_hire_app"] = a
                hire = (start, outlet, role, a["source"], req, a["_person"])
            else:
                a["status"] = "Offer Declined"
            offer_at = a["decided_at"]
        return req, apps, hire

    def employed(self, e, day):
        return e["hired_date"] <= day and (e["terminated_date"] is None or day < e["terminated_date"])

    def attendance(self, emps, end, out):
        ft, pt = self.hr["full_time"], self.hr["part_time"]
        rows = out["attendance"]
        for eid in sorted(emps):
            e = emps[eid]
            is_ft = e["employment_type"] == "Full-time"
            day_off = self.rnd_for("hr", "dayoff", eid).randint(0, 6)
            shift_idx = self.rnd_for("hr", "shift", eid).randint(0, 1)
            day = max(self.start, e["hired_date"])
            while day <= end:
                if not self.employed(e, day):
                    break
                rnd = self.rnd_for("hr", "att", eid, day)
                scheduled = ft["shift_hours"] if is_ft else pt["shift_hours"]
                works = (day.weekday() != day_off) if is_ft else (rnd.random() < pt["shift_prob"])
                if day in self.closed or not works:
                    day += dt.timedelta(days=1)
                    continue
                hour = SHIFT_START[e["job_role"]][shift_idx] if is_ft else (11, 16)[shift_idx]
                late, ot, status = 0, 0.0, "Present"
                if is_ft and rnd.random() < ft["leave_days_per_year"] / 313:
                    status = "Leave"
                elif rnd.random() < (ft["absent_prob"] if is_ft else pt["absent_prob"]):
                    status = "Absent"
                else:
                    if rnd.random() < (ft["late_prob"] if is_ft else pt["late_prob"]):
                        status, late = "Late", rnd.randint(5, 40)
                    if is_ft:
                        ro = ft["rainy_overtime"]
                        if (e["outlet_id"] == ro["outlet"] and e["job_role"] == ro["role"]
                                and self.day_flags(day)["rain"] and rnd.random() < ro["prob"]):
                            ot = float(rnd.randint(*ro["hours"]))
                        elif rnd.random() < ft["overtime_prob"]:
                            ot = float(rnd.randint(1, 2))
                worked = 0.0 if status in ("Absent", "Leave") else round(scheduled - late / 60 + ot, 1)
                cin = self.ts(day, hour) + dt.timedelta(minutes=late) if worked else None
                cout = self.ts(day, hour) + dt.timedelta(hours=scheduled + ot) if worked else None
                rows.append(dict(attendance_id=f"{eid}-{day:%Y%m%d}", employee_id=eid, outlet_id=e["outlet_id"],
                                 work_date=day, status=status, scheduled_hours=float(scheduled), clock_in_at=cin,
                                 clock_out_at=cout, late_minutes=late, worked_hours=worked, overtime_hours=ot))
                day += dt.timedelta(days=1)

    def reviews(self, emps, end, out):
        att = defaultdict(list)
        for a in out["attendance"]:
            att[a["employee_id"]].append(a)
        managers = {e["outlet_id"]: eid for eid, e in sorted(emps.items())
                    if e["job_role"] == "Outlet Manager" and e["employment_type"] == "Full-time"}
        for r in self.hr["reviews"]:
            if r["reviewed_on"] > end:
                continue
            for eid in sorted(emps):
                e = emps[eid]
                if not self.employed(e, r["reviewed_on"]):
                    continue
                if (r["end"] - max(r["start"], e["hired_date"])).days < 60:
                    continue
                rows = [a for a in att[eid] if r["start"] <= a["work_date"] <= r["end"]]
                if not rows:
                    continue
                late = sum(a["status"] == "Late" for a in rows) / len(rows)
                absent = sum(a["status"] == "Absent" for a in rows) / len(rows)
                rnd = self.rnd_for("hr", "review", r["period"], eid)
                score = 3.8 + rnd.gauss(0, 0.7) - 8 * late - 15 * absent
                rating = int(min(5, max(1, round(score))))
                reviewer = None if e["job_role"] == "Outlet Manager" else managers.get(e["outlet_id"])
                out["performance_reviews"].append(dict(
                    review_id=f"RV-{r['period']}-{eid}", employee_id=eid, review_period=r["period"],
                    reviewer_id=reviewer, rating=rating,
                    goals_met_pct=round(min(100, max(0, 55 + 8 * rating + rnd.gauss(0, 5))), 1),
                    reviewed_at=self.ts(r["reviewed_on"], 10)))

    def compensation(self, emps, end, out):
        hr = self.hr
        ratings = {(v["employee_id"], v["review_period"]): v["rating"] for v in out["performance_reviews"]}
        raise_day = hr["annual_raise_date"]
        first_review = hr["reviews"][0]
        for eid in sorted(emps):
            e = emps[eid]
            if e["employment_type"] == "Part-time":
                out["employee_compensation"].append(dict(
                    employee_id=eid, effective_from=e["hired_date"], effective_to=None, base_salary_monthly=None,
                    hourly_rate=float(hr["part_time"]["hourly_rate"]), allowance_monthly=0.0, change_reason="Initial"))
                continue
            rnd = self.rnd_for("hr", "salary", eid)
            base = hr["base_salary"][e["job_role"]] * hr["outlet_salary_factor"][e["outlet_id"]] * rnd.gauss(1, 0.03)
            base = round(base / 50_000) * 50_000
            rows = [dict(employee_id=eid, effective_from=e["hired_date"], effective_to=None,
                         base_salary_monthly=float(base), hourly_rate=None,
                         allowance_monthly=float(hr["allowance_monthly"]), change_reason="Initial")]
            rating = ratings.get((eid, first_review["period"]))
            if rating is not None and first_review["reviewed_on"] <= end:    # kenaikan berlaku mundur ke 1 Jan
                rows[0]["effective_to"] = raise_day
                new = round(base * (1 + hr["raise_pct_by_rating"][rating] / 100) / 50_000) * 50_000
                rows.append(dict(rows[0], effective_from=raise_day, effective_to=None,
                                 base_salary_monthly=float(new), change_reason="Annual Review"))
            out["employee_compensation"].extend(rows)

    def payroll(self, emps, end, out):
        hr = self.hr
        comp = defaultdict(list)
        for c in out["employee_compensation"]:
            comp[c["employee_id"]].append(c)
        att = defaultdict(list)
        for a in out["attendance"]:
            att[(a["employee_id"], a["work_date"].replace(day=1))].append(a)
        month = self.start.replace(day=1)
        while True:
            nxt = (month + dt.timedelta(days=32)).replace(day=1)
            month_end = nxt - dt.timedelta(days=1)
            if month_end > end:
                break
            for eid in sorted(emps):
                e = emps[eid]
                if not any(self.employed(e, d) for d in (month, month_end)) and not (
                        month <= e["hired_date"] <= month_end):
                    continue
                rows = att[(eid, month)]
                c = next((c for c in comp[eid] if c["effective_from"] <= month_end
                          and (c["effective_to"] is None or month_end < c["effective_to"])), comp[eid][-1])
                if e["employment_type"] == "Full-time":
                    base = c["base_salary_monthly"]
                    hourly = base / hr["standard_hours_per_month"]
                    allow = c["allowance_monthly"]
                    ot = round(sum(a["overtime_hours"] for a in rows) * hourly * hr["overtime_multiplier"], 2)
                    absence = round(sum(a["status"] == "Absent" for a in rows) * base / 26, 2)
                    bpjs = round(base * hr["bpjs_pct"] / 100, 2)
                else:
                    base = round(sum(a["worked_hours"] for a in rows) * c["hourly_rate"], 2)
                    allow = ot = absence = bpjs = 0.0
                    if base == 0:
                        continue
                base, allow = round(base, 2), round(allow, 2)
                out["payroll"].append(dict(
                    payroll_id=f"PR-{eid}-{month:%Y%m}", employee_id=eid, outlet_id=e["outlet_id"],
                    period_month=month, base_pay=base, allowance_pay=allow, overtime_pay=ot,
                    absence_deduction=absence, bpjs_deduction=bpjs,
                    net_pay=round(base + allow + ot - absence - bpjs, 2), paid_at=self.ts(month_end, 17)))
            month = nxt


# ---------------------------------------------------------------------- penulisan ke DB
TABLES = {
    # tabel: (kolom, primary key)
    "employees": (["employee_id", "outlet_id", "full_name", "phone_number", "job_role", "hired_date",
                   "terminated_date", "national_id", "birth_date", "gender", "email", "employment_type",
                   "hire_source", "termination_reason"], ["employee_id"]),
    "employee_compensation": (["employee_id", "effective_from", "effective_to", "base_salary_monthly",
                               "hourly_rate", "allowance_monthly", "change_reason"], ["employee_id", "effective_from"]),
    "attendance": (["attendance_id", "employee_id", "outlet_id", "work_date", "status", "scheduled_hours",
                    "clock_in_at", "clock_out_at", "late_minutes", "worked_hours", "overtime_hours"], ["attendance_id"]),
    "payroll": (["payroll_id", "employee_id", "outlet_id", "period_month", "base_pay", "allowance_pay",
                 "overtime_pay", "absence_deduction", "bpjs_deduction", "net_pay", "paid_at"], ["payroll_id"]),
    "performance_reviews": (["review_id", "employee_id", "review_period", "reviewer_id", "rating",
                             "goals_met_pct", "reviewed_at"], ["review_id"]),
    "job_requisitions": (["requisition_id", "outlet_id", "job_role", "employment_type", "reason",
                          "replaces_employee_id", "opened_date", "filled_date", "filled_by_employee_id"],
                         ["requisition_id"]),
    "job_applications": (["application_id", "requisition_id", "candidate_name", "candidate_phone", "source",
                          "applied_at", "screened_at", "interviewed_at", "offered_at", "decided_at", "status",
                          "hired_employee_id"], ["application_id"]),
}


def upsert(conn, table, rows):
    """Insert baru; update hanya bila nilai berubah (updated_at dinaikkan). -> (inserted, updated)."""
    cols, pk = TABLES[table]
    if not rows:
        return 0, 0
    upd = [c for c in cols if c not in pk]
    col_list = ", ".join(cols)
    with conn.cursor() as cur:
        cur.execute(f"create temp table _hr_stage (like fnb.{table} including defaults) on commit drop")
        with cur.copy(f"copy _hr_stage ({col_list}) from stdin") as cp:
            for r in rows:
                cp.write_row([r[c] for c in cols])
        cur.execute(f"""
            insert into fnb.{table} as t ({col_list})
            select {col_list} from _hr_stage
            on conflict ({", ".join(pk)}) do update
               set {", ".join(f"{c} = excluded.{c}" for c in upd)}, updated_at = now()
             where ({", ".join(f"t.{c}" for c in upd)}) is distinct from ({", ".join(f"excluded.{c}" for c in upd)})
            returning (xmax = 0) as inserted""")
        flags = [r[0] for r in cur.fetchall()]
        cur.execute("drop table _hr_stage")
    return sum(flags), len(flags) - sum(flags)


def sync(conn, sim, end):
    core = [dict(zip(("employee_id", "outlet_id", "full_name", "phone_number", "job_role", "hired_date"), r))
            for r in conn.execute("select employee_id, outlet_id, full_name, phone_number, job_role, hired_date "
                                  "from fnb.employees where employee_id not like 'P%' order by employee_id")]
    world = sim.run(core, end)
    summary = {}
    with conn.transaction():
        for table in TABLES:                                        # urutan aman untuk foreign key
            rows = world[table]
            if table == "job_requisitions":
                rows = [{k: v for k, v in r.items() if not k.startswith("_")} for r in rows]
            summary[table] = upsert(conn, table, rows)
    return summary
