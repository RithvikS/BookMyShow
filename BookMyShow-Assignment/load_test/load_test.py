"""
BookMyShow-style ticketing backend - concurrency & load test.

Fires many simultaneous users at the stored procedures in sql/02_procedures.sql
and then asserts, from the database itself, that the guarantees hold:

  S1  Hot-seat stampede    : N users click the SAME 2 seats at the same instant
                             -> exactly 1 hold, N-1 clean rejections, 0 errors.
  S2  Sold-out rush        : N users grab random 1-4 seat blocks of one show
                             -> no seat ever has two owners; sold <= capacity.
  S3  Webhook storm        : every payment webhook delivered 5x concurrently
                             -> each booking confirmed exactly once.
  S4  Expiry race          : holds lapse; new buyers and the old buyers' late
                             payments hit the same seats at the same time
                             -> every seat ends with exactly one owner.
  S5  Pessimistic vs optimistic on the stampede (same inputs)
                             -> both are correct; compare wasted work/latency.

Usage (against a TEST database loaded with sql/01..03):
    pip install -r requirements.txt
    python load_test.py --host 127.0.0.1 --port 3306 --user root --password <pwd>

WARNING: the script clears bookings on the 5 shows it uses (day +6, theatre 1).
Never point it at a production database.
"""

import argparse
import json
import os
import random
import statistics
import threading
import time
import uuid
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

import pymysql

ARGS = None
DEADLOCKS = Counter()          # MySQL 1213/1205 seen, per scenario (retried like a real client)
CURRENT = {"scenario": ""}
_dl_lock = threading.Lock()


def note_deadlock(code):
    with _dl_lock:
        DEADLOCKS[(CURRENT["scenario"], code)] += 1


def connect():
    return pymysql.connect(host=ARGS.host, port=ARGS.port, user=ARGS.user,
                           password=ARGS.password, database=ARGS.database,
                           autocommit=True)


# --------------------------------------------------------------------------- helpers
def call_hold(conn, user_id, show_id, seat_ids, hold_seconds=600, key=None):
    """Returns (status, booking_id, latency_ms). Retries once on deadlock/timeout."""
    key = key or str(uuid.uuid4())
    t0 = time.perf_counter()
    for attempt in range(3):
        try:
            with conn.cursor() as cur:
                cur.execute("CALL sp_hold_seats(%s,%s,%s,%s,%s,@b,@s)",
                            (user_id, show_id, json.dumps(seat_ids), key, hold_seconds))
                cur.execute("SELECT @b, @s")
                b, s = cur.fetchone()
            return s, b, (time.perf_counter() - t0) * 1000
        except pymysql.err.OperationalError as e:
            if e.args[0] in (1213, 1205):                  # deadlock / lock wait timeout
                note_deadlock(e.args[0])
                if attempt < 2:
                    continue
            return f"ERROR {e.args[0]}", None, (time.perf_counter() - t0) * 1000


def call_webhook(conn, event_id, order_id, amount, event_type="payment.captured"):
    """A gateway retries a failed delivery; we do the same (and count it)."""
    t0 = time.perf_counter()
    for attempt in range(3):
        try:
            with conn.cursor() as cur:
                cur.execute("CALL sp_process_payment_webhook('RAZORPAY',%s,%s,%s,%s,%s,%s,@r)",
                            (event_id, event_type, order_id, "pay_" + order_id, amount,
                             json.dumps({"order_id": order_id, "amount": float(amount) * 100})))
                cur.execute("SELECT @r")
                return cur.fetchone()[0], (time.perf_counter() - t0) * 1000
        except pymysql.err.OperationalError as e:
            if e.args[0] in (1213, 1205):
                note_deadlock(e.args[0])
                if attempt < 2:
                    continue
            return f"ERROR {e.args[0]}", (time.perf_counter() - t0) * 1000


def create_payment(conn, booking_id, order_id):
    with conn.cursor() as cur:
        cur.execute("CALL sp_create_payment(%s,'RAZORPAY',%s,@p,@a)", (booking_id, order_id))
        cur.execute("SELECT @p, @a")
        return cur.fetchone()


def pct(values, p):
    if not values:
        return 0.0
    values = sorted(values)
    k = max(0, min(len(values) - 1, int(round(p / 100.0 * (len(values) - 1)))))
    return values[k]


def latency_summary(lat):
    return {"p50_ms": round(pct(lat, 50), 1), "p95_ms": round(pct(lat, 95), 1),
            "p99_ms": round(pct(lat, 99), 1), "max_ms": round(max(lat), 1) if lat else 0}


class Pool:
    """One connection per worker thread (connections are not thread-safe)."""

    def __init__(self):
        self.local = threading.local()
        self.all = []
        self.lock = threading.Lock()

    def get(self):
        if not hasattr(self.local, "conn"):
            self.local.conn = connect()
            with self.lock:
                self.all.append(self.local.conn)
        return self.local.conn

    def close(self):
        for c in self.all:
            c.close()


def run_concurrently(fn, items, workers):
    """Start all tasks behind a barrier so they really collide."""
    pool = Pool()
    barrier = threading.Barrier(min(workers, len(items)))
    warmed = threading.local()

    def task(item):
        conn = pool.get()
        if not getattr(warmed, "done", False):
            warmed.done = True
            try:
                barrier.wait(timeout=30)
            except threading.BrokenBarrierError:
                pass
        return fn(conn, item)

    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=workers) as ex:
        results = list(ex.map(task, items))
    elapsed = time.perf_counter() - t0
    pool.close()
    return results, elapsed


# --------------------------------------------------------------------------- setup
def pick_shows(conn):
    with conn.cursor() as cur:
        cur.execute("""SELECT s.show_id FROM shows s JOIN screen sc ON sc.screen_id = s.screen_id
                       WHERE sc.theatre_id = 1 AND s.status = 'SCHEDULED'
                         AND s.start_time >= CURDATE() + INTERVAL 6 DAY
                         AND s.start_time <  CURDATE() + INTERVAL 7 DAY
                       ORDER BY s.show_id LIMIT 5""")
        shows = [r[0] for r in cur.fetchall()]
    assert len(shows) == 5, "load sql/03_sample_data.sql first"
    return shows


def reset_shows(conn, shows):
    ids = ",".join(str(s) for s in shows)
    with conn.cursor() as cur:
        cur.execute(f"UPDATE show_seat SET booking_id = NULL WHERE show_id IN ({ids})")
        cur.execute(f"""DELETE w FROM payment_webhook_event w JOIN payment p ON p.payment_id = w.payment_id
                        JOIN booking b ON b.booking_id = p.booking_id WHERE b.show_id IN ({ids})""")
        cur.execute(f"DELETE p FROM payment p JOIN booking b ON b.booking_id = p.booking_id WHERE b.show_id IN ({ids})")
        cur.execute(f"DELETE bs FROM booking_seat bs JOIN booking b ON b.booking_id = bs.booking_id WHERE b.show_id IN ({ids})")
        cur.execute(f"DELETE FROM booking WHERE show_id IN ({ids})")


def seats_of(conn, show_id):
    with conn.cursor() as cur:
        cur.execute("""SELECT se.seat_id, se.row_label, se.seat_number FROM show_seat ss
                       JOIN seat se ON se.seat_id = ss.seat_id WHERE ss.show_id = %s
                       ORDER BY se.row_label, se.seat_number""", (show_id,))
        return cur.fetchall()


def double_owner_violations(conn, show_id):
    """Seats that two *active* bookings both believe they own (must be 0)."""
    with conn.cursor() as cur:
        cur.execute("""
            SELECT COUNT(*) FROM (
              SELECT bs.seat_id FROM booking_seat bs JOIN booking b ON b.booking_id = bs.booking_id
              WHERE b.show_id = %s
                AND (b.status = 'CONFIRMED' OR (b.status = 'PENDING' AND b.hold_expires_at > NOW(3)))
              GROUP BY bs.seat_id HAVING COUNT(*) > 1) x""", (show_id,))
        dup = cur.fetchone()[0]
        cur.execute("""
            SELECT COUNT(*) FROM booking b JOIN booking_seat bs ON bs.booking_id = b.booking_id
            LEFT JOIN show_seat ss ON ss.show_id = b.show_id AND ss.seat_id = bs.seat_id
                                   AND ss.booking_id = b.booking_id
            WHERE b.show_id = %s AND ss.seat_id IS NULL
              AND (b.status = 'CONFIRMED' OR (b.status = 'PENDING' AND b.hold_expires_at > NOW(3)))""",
                    (show_id,))
        lost = cur.fetchone()[0]
    return dup, lost


# --------------------------------------------------------------------------- scenarios
def s1_stampede(conn, show_id, users):
    seats = seats_of(conn, show_id)
    target = [s[0] for s in seats if s[1] == "C" and s[2] in (5, 6)]
    results, elapsed = run_concurrently(
        lambda c, u: call_hold(c, u % 5 + 1, show_id, target), list(range(users)), ARGS.workers)
    statuses = Counter(r[0] for r in results)
    dup, lost = double_owner_violations(conn, show_id)
    ok = statuses.get("HELD", 0) == 1 and statuses.get("SEATS_UNAVAILABLE", 0) == users - 1 \
        and dup == 0 and lost == 0
    return {"scenario": "S1 Hot-seat stampede (pessimistic)",
            "setup": f"{users} users, same 2 seats (C5,C6), released together",
            "outcomes": dict(statuses), "double_owned_seats": dup, "lost_holds": lost,
            "throughput_rps": round(users / elapsed, 1), **latency_summary([r[2] for r in results]),
            "passed": ok}


def s2_rush(conn, show_id, users):
    seats = seats_of(conn, show_id)
    by_row = {}
    for sid, row, num in seats:
        by_row.setdefault(row, []).append(sid)
    rng = random.Random(42)
    requests = []
    for u in range(users):
        row = rng.choice(sorted(by_row))
        n = rng.randint(1, 4)
        start = rng.randint(0, len(by_row[row]) - n)
        requests.append((u % 5 + 1, by_row[row][start:start + n]))
    results, elapsed = run_concurrently(
        lambda c, r: call_hold(c, r[0], show_id, r[1]), requests, ARGS.workers)
    statuses = Counter(r[0] for r in results)
    seats_sold = sum(len(req[1]) for req, res in zip(requests, results) if res[0] == "HELD")
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM show_seat WHERE show_id = %s AND booking_id IS NOT NULL", (show_id,))
        owned_rows = cur.fetchone()[0]
    dup, lost = double_owner_violations(conn, show_id)
    ok = dup == 0 and lost == 0 and seats_sold == owned_rows <= len(seats) \
        and not any(s.startswith("ERROR") for s in statuses)
    return {"scenario": "S2 Sold-out rush",
            "setup": f"{users} users, random 1-4 seat blocks, {len(seats)}-seat show",
            "outcomes": dict(statuses), "seats_sold": seats_sold, "show_seat_rows_owned": owned_rows,
            "capacity": len(seats), "double_owned_seats": dup, "lost_holds": lost,
            "throughput_rps": round(users / elapsed, 1), **latency_summary([r[2] for r in results]),
            "passed": ok}


def s3_webhook_storm(conn, show_id, copies):
    seats = [s[0] for s in seats_of(conn, show_id)]
    orders = []
    for i in range(0, 50 * 1, 1):                     # 50 bookings, 1 seat each
        st, b, _ = call_hold(conn, i % 5 + 1, show_id, [seats[i]])
        assert st == "HELD", st
        order_id = f"order_S3_{b}"
        _, amount = create_payment(conn, b, order_id)
        orders.append((b, order_id, amount))
    deliveries = [(f"evt_S3_{b}", o, a) for b, o, a in orders for _ in range(copies)]
    random.Random(7).shuffle(deliveries)
    results, elapsed = run_concurrently(
        lambda c, d: call_webhook(c, d[0], d[1], d[2]), deliveries, ARGS.workers)
    outcomes = Counter(r[0] for r in results)
    ids = ",".join(str(b) for b, _, _ in orders)
    with conn.cursor() as cur:
        cur.execute(f"SELECT COUNT(*) FROM booking WHERE booking_id IN ({ids}) AND status = 'CONFIRMED'")
        confirmed = cur.fetchone()[0]
        cur.execute(f"SELECT COUNT(*) FROM payment WHERE booking_id IN ({ids}) AND status = 'CAPTURED'")
        captured = cur.fetchone()[0]
        cur.execute(f"""SELECT COUNT(*) FROM payment_webhook_event w JOIN payment p ON p.payment_id = w.payment_id
                        WHERE p.booking_id IN ({ids})""")
        events = cur.fetchone()[0]
    ok = outcomes.get("BOOKING_CONFIRMED", 0) == 50 and confirmed == 50 and captured == 50 \
        and events == 50 and outcomes.get("DUPLICATE_EVENT", 0) == 50 * (copies - 1)
    return {"scenario": "S3 Webhook storm (idempotency)",
            "setup": f"50 paid bookings, each webhook delivered {copies}x concurrently ({len(deliveries)} calls)",
            "outcomes": dict(outcomes), "bookings_confirmed": confirmed, "payments_captured": captured,
            "webhook_rows_stored": events, "throughput_rps": round(len(deliveries) / elapsed, 1),
            **latency_summary([r[1] for r in results]), "passed": ok}


def s4_expiry_race(conn, show_id, n=30):
    seats = [s[0] for s in seats_of(conn, show_id)][:n]
    old = []
    for i, sid in enumerate(seats):
        st, b, _ = call_hold(conn, 1, show_id, [sid], hold_seconds=2)
        assert st == "HELD", st
        order_id = f"order_S4_{b}"
        _, amount = create_payment(conn, b, order_id)
        old.append((sid, b, order_id, amount))
    time.sleep(2.5)                                        # every hold has lapsed
    tasks = []
    for sid, b, order_id, amount in old:
        tasks.append(("buy", sid))                         # a new buyer wants the seat
        tasks.append(("pay", (order_id, amount)))          # the old buyer's late payment
    random.Random(3).shuffle(tasks)

    def work(c, t):
        if t[0] == "buy":
            return ("buy",) + call_hold(c, 2, show_id, [t[1]])[:2]
        return ("pay", call_webhook(c, "evt_" + t[1][0], t[1][0], t[1][1])[0], None)

    results, elapsed = run_concurrently(work, tasks, ARGS.workers)
    outcomes = Counter(f"{r[0]}:{r[1]}" for r in results)
    # every seat must end with exactly one active owner
    bad = 0
    with conn.cursor() as cur:
        for sid, b, _, _ in old:
            cur.execute("""SELECT COUNT(*) FROM booking_seat bs JOIN booking b ON b.booking_id = bs.booking_id
                           WHERE b.show_id = %s AND bs.seat_id = %s
                             AND (b.status = 'CONFIRMED' OR (b.status = 'PENDING' AND b.hold_expires_at > NOW(3)))""",
                        (show_id, sid))
            if cur.fetchone()[0] != 1:
                bad += 1
    dup, lost = double_owner_violations(conn, show_id)
    confirmed_late = outcomes.get("pay:BOOKING_CONFIRMED", 0)
    new_holds = outcomes.get("buy:HELD", 0)
    ok = bad == 0 and dup == 0 and lost == 0 and confirmed_late + new_holds == n
    return {"scenario": "S4 Expiry race (lapsed hold vs new buyer vs late payment)",
            "setup": f"{n} seats held for 2 s, then new buyers + late payments fired together",
            "outcomes": dict(outcomes), "seats_without_exactly_one_owner": bad,
            "double_owned_seats": dup, "lost_holds": lost, "passed": ok}


def s5_optimistic(conn, show_id, users):
    """Same stampede as S1 but with optimistic compare-and-set on show_seat.version."""
    seats = seats_of(conn, show_id)
    target = [s[0] for s in seats if s[1] == "C" and s[2] in (5, 6)]
    with conn.cursor() as cur:
        cur.execute("SELECT seat_id, version FROM show_seat WHERE show_id = %s AND seat_id IN (%s, %s)",
                    (show_id, target[0], target[1]))
        versions = dict(cur.fetchall())

    def attempt(c, u):
        t0 = time.perf_counter()
        c.autocommit(False)
        try:
            with c.cursor() as cur:
                cur.execute("""INSERT INTO booking (user_id, show_id, status, idempotency_key, hold_expires_at)
                               VALUES (%s, %s, 'PENDING', %s, NOW(3) + INTERVAL 10 MINUTE)""",
                            (u % 5 + 1, show_id, str(uuid.uuid4())))
                bid = cur.lastrowid
                won = 0
                for sid in target:
                    cur.execute("""INSERT INTO booking_seat (booking_id, seat_id, price)
                                   SELECT %s, se.seat_id, sp.price FROM seat se
                                   JOIN show_price sp ON sp.show_id = %s AND sp.seat_type_id = se.seat_type_id
                                   WHERE se.seat_id = %s""", (bid, show_id, sid))
                    won += cur.execute("""UPDATE show_seat SET booking_id = %s, version = version + 1
                                          WHERE show_id = %s AND seat_id = %s AND version = %s""",
                                       (bid, show_id, sid, versions[sid]))
            if won == len(target):
                c.commit()
                return "HELD", (time.perf_counter() - t0) * 1000
            c.rollback()
            return "CONFLICT_ROLLED_BACK", (time.perf_counter() - t0) * 1000
        except pymysql.err.OperationalError as e:
            c.rollback()
            return f"ERROR {e.args[0]}", (time.perf_counter() - t0) * 1000
        finally:
            c.autocommit(True)

    results, elapsed = run_concurrently(attempt, list(range(users)), ARGS.workers)
    statuses = Counter(r[0] for r in results)
    dup, lost = double_owner_violations(conn, show_id)
    ok = statuses.get("HELD", 0) == 1 and dup == 0 and lost == 0
    return {"scenario": "S5 Hot-seat stampede (optimistic CAS, for comparison)",
            "setup": f"{users} users, same 2 seats, version compare-and-set",
            "outcomes": dict(statuses), "wasted_transactions": users - statuses.get("HELD", 0),
            "double_owned_seats": dup, "lost_holds": lost,
            "throughput_rps": round(users / elapsed, 1), **latency_summary([r[1] for r in results]),
            "passed": ok}


# --------------------------------------------------------------------------- main
def main():
    global ARGS
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=3306)
    ap.add_argument("--user", default="root")
    ap.add_argument("--password", default=os.environ.get("MYSQL_PASSWORD", ""))
    ap.add_argument("--database", default="bookmyshow")
    ap.add_argument("--users", type=int, default=500, help="simulated users per scenario")
    ap.add_argument("--workers", type=int, default=100, help="concurrent connections (< max_connections)")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "results.json"))
    ARGS = ap.parse_args()

    conn = connect()
    shows = pick_shows(conn)
    reset_shows(conn, shows)
    with conn.cursor() as cur:
        cur.execute("SELECT VERSION(), @@transaction_isolation")
        version, isolation = cur.fetchone()

    report = {"mysql_version": version, "isolation": isolation, "workers": ARGS.workers,
              "users": ARGS.users, "run_at": time.strftime("%Y-%m-%d %H:%M:%S"), "scenarios": []}
    for fn, show, arg in ((s1_stampede, shows[0], ARGS.users),
                          (s2_rush, shows[1], ARGS.users),
                          (s3_webhook_storm, shows[2], 5),
                          (s4_expiry_race, shows[3], 30),
                          (s5_optimistic, shows[4], ARGS.users)):
        CURRENT["scenario"] = fn.__name__
        res = fn(conn, show, arg)
        res["deadlocks_or_lock_timeouts"] = sum(v for (sc, _), v in DEADLOCKS.items() if sc == fn.__name__)
        report["scenarios"].append(res)
        print(f"[{'PASS' if res['passed'] else 'FAIL'}] {res['scenario']}")
        for k, v in res.items():
            if k not in ("scenario", "passed"):
                print(f"        {k}: {v}")

    report["all_passed"] = all(s["passed"] for s in report["scenarios"])
    with open(ARGS.out, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    print("\nALL PASSED" if report["all_passed"] else "\nSOME SCENARIOS FAILED")
    conn.close()
    raise SystemExit(0 if report["all_passed"] else 1)


if __name__ == "__main__":
    main()
