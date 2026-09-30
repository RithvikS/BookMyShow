-- =============================================================================
--  BookMyShow-style Ticketing Backend  |  Walk-through + integrity checks
--  Run after 01..04:  mysql -u root -p bookmyshow < sql/05_demo_and_checks.sql
--  Demonstrates, step by step, the guarantees claimed in the design document.
-- =============================================================================

USE bookmyshow;

SET @show = (SELECT show_id FROM shows
             WHERE screen_id = 1 AND start_time = TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '21:15:00'));
SET @f5 = (SELECT seat_id FROM seat WHERE screen_id = 1 AND row_label = 'F' AND seat_number = 5);
SET @f6 = (SELECT seat_id FROM seat WHERE screen_id = 1 AND row_label = 'F' AND seat_number = 6);
SET @e5 = (SELECT seat_id FROM seat WHERE screen_id = 1 AND row_label = 'E' AND seat_number = 5);

-- 1) Karthik holds F5 + F6 --------------------------------------------- HELD
CALL sp_hold_seats(4, @show, JSON_ARRAY(@f5, @f6), 'a0000000-0000-0000-0000-000000000001', 600, @b1, @st);
SELECT '1. Karthik holds F5,F6' AS step, @b1 AS booking_id, @st AS status;

-- 2) Same click retried (double-click / network retry) ---------- ALREADY_HELD
CALL sp_hold_seats(4, @show, JSON_ARRAY(@f5, @f6), 'a0000000-0000-0000-0000-000000000001', 600, @b, @st);
SELECT '2. Same request retried' AS step, @b AS booking_id, @st AS status;

-- 3) Meera tries F6 while it is held ------------------------ SEATS_UNAVAILABLE
CALL sp_hold_seats(5, @show, JSON_ARRAY(@f6), 'a0000000-0000-0000-0000-000000000002', 600, @b, @st);
SELECT '3. Meera tries F6' AS step, @b AS booking_id, @st AS status;

-- 4) Meera tries E5 (held by sample booking 2) -------------- SEATS_UNAVAILABLE
CALL sp_hold_seats(5, @show, JSON_ARRAY(@e5), 'a0000000-0000-0000-0000-000000000003', 600, @b, @st);
SELECT '4. Meera tries E5' AS step, @b AS booking_id, @st AS status;

-- 5) Karthik pays; the gateway delivers the SAME webhook three times
CALL sp_create_payment(@b1, 'RAZORPAY', 'order_DEMO0001', @pay, @amt);
SELECT '5a. Payment order created' AS step, @pay AS payment_id, @amt AS amount;

CALL sp_process_payment_webhook('RAZORPAY', 'evt_DEMO0001', 'payment.captured', 'order_DEMO0001',
                                'pay_DEMO0001', @amt, JSON_OBJECT('amount', @amt * 100), @r);
SELECT '5b. Webhook delivery #1' AS step, @r AS outcome;
CALL sp_process_payment_webhook('RAZORPAY', 'evt_DEMO0001', 'payment.captured', 'order_DEMO0001',
                                'pay_DEMO0001', @amt, JSON_OBJECT('amount', @amt * 100), @r);
SELECT '5c. Webhook delivery #2 (duplicate)' AS step, @r AS outcome;
CALL sp_process_payment_webhook('RAZORPAY', 'evt_DEMO0001_retry', 'payment.captured', 'order_DEMO0001',
                                'pay_DEMO0001', @amt, JSON_OBJECT('amount', @amt * 100), @r);
SELECT '5d. Different event id, same payment' AS step, @r AS outcome;

-- 6) Timed hold: Priya holds G1 for 1 second and does not pay ---------------
SET @g1 = (SELECT seat_id FROM seat WHERE screen_id = 1 AND row_label = 'G' AND seat_number = 1);
CALL sp_hold_seats(3, @show, JSON_ARRAY(@g1), 'a0000000-0000-0000-0000-000000000004', 1, @b6, @st);
CALL sp_create_payment(@b6, 'RAZORPAY', 'order_DEMO0006', @pay6, @amt6);
SELECT '6a. Priya holds G1 for 1 s' AS step, @b6 AS booking_id, @st AS status;
DO SLEEP(1.2);

-- 7) Hold lapsed -> Rahul can take G1 immediately (no job needed) ------- HELD
CALL sp_hold_seats(2, @show, JSON_ARRAY(@g1), 'a0000000-0000-0000-0000-000000000005', 600, @b7, @st);
SELECT '7. Rahul takes G1 after expiry' AS step, @b7 AS booking_id, @st AS status;

-- 8) Priya's payment arrives late -> refund, Rahul keeps the seat --------------
CALL sp_process_payment_webhook('RAZORPAY', 'evt_DEMO0006', 'payment.captured', 'order_DEMO0006',
                                'pay_DEMO0006', @amt6, JSON_OBJECT('amount', @amt6 * 100), @r);
SELECT '8. Priya''s late payment' AS step, @r AS outcome;

-- 9) Housekeeping job --------------------------------------------------------
CALL sp_release_expired_holds(500, @released);
SELECT '9. Expired holds released by job' AS step, @released AS released;

-- -----------------------------------------------------------------------------
-- Seat map for the show (what the seat-selection screen renders)
-- -----------------------------------------------------------------------------
SELECT se.row_label,
       GROUP_CONCAT(
           CONCAT(se.seat_number, ':',
                  CASE
                      WHEN b.status = 'CONFIRMED' THEN 'BOOKED'
                      WHEN b.status = 'PENDING' AND b.hold_expires_at > NOW(3) THEN 'HELD'
                      ELSE 'FREE'
                  END)
           ORDER BY se.seat_number SEPARATOR ' ') AS seats
FROM show_seat ss
         JOIN seat se ON se.seat_id = ss.seat_id
         LEFT JOIN booking b ON b.booking_id = ss.booking_id
WHERE ss.show_id = @show
GROUP BY se.row_label
ORDER BY se.row_label;

-- -----------------------------------------------------------------------------
-- Optimistic-locking variant (for comparison; see design doc section 6)
-- Read the version, then compare-and-set. 0 rows affected => someone else won.
-- -----------------------------------------------------------------------------
SET @h1 = (SELECT seat_id FROM seat WHERE screen_id = 1 AND row_label = 'H' AND seat_number = 1);
SELECT version INTO @v FROM show_seat WHERE show_id = @show AND seat_id = @h1;

START TRANSACTION;
INSERT INTO booking (user_id, show_id, status, idempotency_key, hold_expires_at)
VALUES (5, @show, 'PENDING', 'a0000000-0000-0000-0000-000000000009', NOW(3) + INTERVAL 10 MINUTE);
SET @ob = LAST_INSERT_ID();
INSERT INTO booking_seat (booking_id, seat_id, price)
SELECT @ob, @h1, price FROM show_price WHERE show_id = @show AND seat_type_id = 3;
UPDATE show_seat
SET booking_id = @ob, version = version + 1
WHERE show_id = @show AND seat_id = @h1
  AND version = @v                       -- the optimistic check
  AND booking_id IS NULL;
SELECT 'Optimistic CAS on H1' AS step, ROW_COUNT() AS rows_won;   -- 1 = won, 0 = lost -> ROLLBACK
COMMIT;

-- -----------------------------------------------------------------------------
-- Integrity checks: EVERY query below must return 0.
-- -----------------------------------------------------------------------------
SELECT 'A seat in two CONFIRMED bookings of the same show' AS invariant, COUNT(*) AS violations
FROM (SELECT b.show_id, bs.seat_id
      FROM booking_seat bs JOIN booking b ON b.booking_id = bs.booking_id
      WHERE b.status = 'CONFIRMED'
      GROUP BY b.show_id, bs.seat_id
      HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'CONFIRMED booking not owning all its seats', COUNT(*)
FROM booking b
         JOIN booking_seat bs ON bs.booking_id = b.booking_id
         LEFT JOIN show_seat ss ON ss.show_id = b.show_id AND ss.seat_id = bs.seat_id AND ss.booking_id = b.booking_id
WHERE b.status = 'CONFIRMED' AND ss.seat_id IS NULL
UNION ALL
SELECT 'Live hold not owning all its seats (lost hold)', COUNT(*)
FROM booking b
         JOIN booking_seat bs ON bs.booking_id = b.booking_id
         LEFT JOIN show_seat ss ON ss.show_id = b.show_id AND ss.seat_id = bs.seat_id AND ss.booking_id = b.booking_id
WHERE b.status = 'PENDING' AND b.hold_expires_at > NOW(3) AND ss.seat_id IS NULL
UNION ALL
SELECT 'CAPTURED payment whose booking is not CONFIRMED', COUNT(*)
FROM payment p JOIN booking b ON b.booking_id = p.booking_id
WHERE p.status = 'CAPTURED' AND b.status <> 'CONFIRMED'
UNION ALL
SELECT 'Booking with more than one CAPTURED payment', COUNT(*)
FROM (SELECT booking_id FROM payment WHERE status = 'CAPTURED'
      GROUP BY booking_id HAVING COUNT(*) > 1) y
UNION ALL
SELECT 'Webhook event received but never processed', COUNT(*)
FROM payment_webhook_event WHERE processed_at IS NULL;
