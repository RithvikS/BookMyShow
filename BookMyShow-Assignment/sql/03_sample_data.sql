-- =============================================================================
--  BookMyShow-style Ticketing Backend  |  P1 - Sample data
--  Run AFTER 01_schema.sql and 02_procedures.sql:
--      mysql -u root -p bookmyshow < sql/03_sample_data.sql
--
--  Show dates are generated RELATIVE TO TODAY (CURDATE() .. CURDATE()+6), exactly
--  like the app's "next 7 dates" strip, so P2 returns rows whenever you run it.
--  Theatre, movie and customer names are fictional.
-- =============================================================================

USE bookmyshow;

-- ---------------------------------------------------------------- locations
INSERT INTO city (city_id, name, state) VALUES
    (1, 'Hyderabad', 'Telangana'),
    (2, 'Bengaluru', 'Karnataka');

INSERT INTO theatre (theatre_id, city_id, name, address_line) VALUES
    (1, 1, 'Aurora Cinemas: Kukatpally',       '4th Floor, Metro Square Mall, Kukatpally, Hyderabad 500072'),
    (2, 1, 'Starlight Multiplex: Gachibowli',  'Level 3, Orbit Towers, Gachibowli, Hyderabad 500032'),
    (3, 2, 'Galaxy Screens: Koramangala',      '80 Feet Road, 4th Block, Koramangala, Bengaluru 560034');

INSERT INTO amenity (amenity_id, name) VALUES
    (1, 'M-Ticket'), (2, 'Food & Beverage'), (3, 'Parking'), (4, 'Wheelchair Access');

INSERT INTO theatre_amenity (theatre_id, amenity_id) VALUES
    (1, 1), (1, 2), (1, 3), (1, 4),
    (2, 1), (2, 2),
    (3, 1), (3, 2), (3, 3);

INSERT INTO screen (screen_id, theatre_id, name) VALUES
    (1, 1, 'Audi 1'), (2, 1, 'Audi 2'), (3, 1, 'IMAX'),
    (4, 2, 'Screen 1'),
    (5, 3, 'Screen 1');

INSERT INTO seat_type (seat_type_id, name) VALUES
    (1, 'CLASSIC'), (2, 'PRIME'), (3, 'RECLINER');

-- 80 seats per screen: rows A-H x seats 1-10.
-- A-D = CLASSIC, E-G = PRIME, H = RECLINER (back row).
INSERT INTO seat (screen_id, row_label, seat_number, seat_type_id)
SELECT sc.screen_id,
       r.row_label,
       n.seat_number,
       CASE WHEN r.row_label IN ('A', 'B', 'C', 'D') THEN 1
            WHEN r.row_label IN ('E', 'F', 'G') THEN 2
            ELSE 3 END
FROM screen sc
         CROSS JOIN (SELECT 'A' AS row_label UNION ALL SELECT 'B' UNION ALL SELECT 'C' UNION ALL SELECT 'D'
                     UNION ALL SELECT 'E' UNION ALL SELECT 'F' UNION ALL SELECT 'G' UNION ALL SELECT 'H') AS r
         CROSS JOIN (SELECT 1 AS seat_number UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                     UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8
                     UNION ALL SELECT 9 UNION ALL SELECT 10) AS n
ORDER BY sc.screen_id, r.row_label, n.seat_number;

-- ---------------------------------------------------------------- catalogue
INSERT INTO movie (movie_id, title, duration_min, certificate, release_date) VALUES
    (1, 'Monsoon Heist',       152, 'UA', '2026-09-18'),
    (2, 'Iron Valley',         169, 'UA', '2026-09-25'),
    (3, 'Chasing Tides',       134, 'U',  '2026-09-11'),
    (4, 'Little Astronaut',    108, 'U',  '2026-08-28'),
    (5, 'The Midnight Ledger', 141, 'A',  '2026-09-25');

INSERT INTO genre (genre_id, name) VALUES
    (1, 'Action'), (2, 'Thriller'), (3, 'Drama'), (4, 'Family'),
    (5, 'Animation'), (6, 'Sci-Fi'), (7, 'Crime');

INSERT INTO movie_genre (movie_id, genre_id) VALUES
    (1, 1), (1, 2), (1, 7),
    (2, 1), (2, 3),
    (3, 3), (3, 4),
    (4, 4), (4, 5), (4, 6),
    (5, 2), (5, 7);

INSERT INTO language (language_id, name) VALUES
    (1, 'English'), (2, 'Hindi'), (3, 'Telugu'), (4, 'Tamil'), (5, 'Kannada');

INSERT INTO show_format (format_id, name) VALUES
    (1, '2D'), (2, '3D'), (3, 'IMAX 2D'), (4, '4DX');

-- ---------------------------------------------------------------- shows
-- A daily schedule template per screen, repeated for today + next 6 days.
-- Start times are spaced so shows on a screen never overlap (film + cleaning).
INSERT INTO shows (movie_id, screen_id, language_id, format_id, start_time)
SELECT t.movie_id, t.screen_id, t.language_id, t.format_id,
       TIMESTAMP(CURDATE() + INTERVAL d.day_offset DAY, t.show_time)
FROM (SELECT 0 AS day_offset UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3
      UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6) AS d
         CROSS JOIN (
    --           movie screen lang fmt  time
    SELECT 2 AS movie_id, 1 AS screen_id, 3 AS language_id, 1 AS format_id, '10:00:00' AS show_time
    UNION ALL SELECT 2, 1, 3, 1, '13:45:00'
    UNION ALL SELECT 1, 1, 2, 1, '17:30:00'
    UNION ALL SELECT 2, 1, 3, 1, '21:15:00'
    UNION ALL SELECT 4, 2, 1, 1, '09:30:00'
    UNION ALL SELECT 3, 2, 3, 1, '12:00:00'
    UNION ALL SELECT 1, 2, 3, 1, '15:00:00'
    UNION ALL SELECT 5, 2, 1, 1, '18:30:00'
    UNION ALL SELECT 3, 2, 2, 1, '22:00:00'
    UNION ALL SELECT 2, 3, 3, 3, '11:00:00'
    UNION ALL SELECT 2, 3, 2, 3, '14:30:00'
    UNION ALL SELECT 2, 3, 3, 3, '18:15:00'
    UNION ALL SELECT 5, 3, 1, 3, '22:00:00'
    UNION ALL SELECT 1, 4, 2, 1, '10:30:00'
    UNION ALL SELECT 3, 4, 3, 2, '14:00:00'
    UNION ALL SELECT 2, 4, 3, 1, '18:00:00'
    UNION ALL SELECT 5, 4, 1, 1, '21:30:00'
    UNION ALL SELECT 4, 5, 5, 1, '11:00:00'
    UNION ALL SELECT 1, 5, 2, 1, '15:00:00'
    UNION ALL SELECT 2, 5, 3, 1, '19:00:00'
    UNION ALL SELECT 5, 5, 1, 1, '22:15:00'
) AS t
ORDER BY d.day_offset, t.screen_id, t.show_time;

-- One show cancelled by the theatre (P2 must not list it)
UPDATE shows
SET status = 'CANCELLED'
WHERE screen_id = 2
  AND start_time = TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '22:00:00');

-- Prices per (show, seat type): CLASSIC 180 / PRIME 250 / RECLINER 450, +150 for IMAX
INSERT INTO show_price (show_id, seat_type_id, price)
SELECT s.show_id,
       st.seat_type_id,
       CASE st.name WHEN 'CLASSIC' THEN 180 WHEN 'PRIME' THEN 250 ELSE 450 END
           + IF(f.name = 'IMAX 2D', 150, 0)
FROM shows s
         JOIN show_format f ON f.format_id = s.format_id
         CROSS JOIN seat_type st;

-- Seat inventory: one row per (show, seat) - created when the show is scheduled
INSERT INTO show_seat (show_id, seat_id)
SELECT s.show_id, se.seat_id
FROM shows s
         JOIN seat se ON se.screen_id = s.screen_id;

-- ---------------------------------------------------------------- customers
INSERT INTO users (user_id, full_name, email, phone) VALUES
    (1, 'Ananya Rao',     'ananya.rao@example.com',     '9800000001'),
    (2, 'Rahul Verma',    'rahul.verma@example.com',    '9800000002'),
    (3, 'Priya Nair',     'priya.nair@example.com',     '9800000003'),
    (4, 'Karthik Reddy',  'karthik.reddy@example.com',  '9800000004'),
    (5, 'Meera Iyer',     'meera.iyer@example.com',     '9800000005');

-- ---------------------------------------------------------------- bookings
-- All three sample bookings are for tomorrow 21:15, Audi 1, Aurora Cinemas.
SET @demo_show = (SELECT show_id FROM shows
                  WHERE screen_id = 1 AND start_time = TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '21:15:00'));

-- Booking 1: CONFIRMED (paid) - recliners H5, H6
-- Booking 2: PENDING hold, expires in 10 minutes - PRIME E5, E6, E7
-- Booking 3: EXPIRED hold (user never paid) - CLASSIC A1; seat already released
INSERT INTO booking (booking_id, user_id, show_id, status, idempotency_key, hold_expires_at, created_at, confirmed_at) VALUES
    (1, 1, @demo_show, 'CONFIRMED', '6f1c1b4e-2a51-4a4e-9a0e-1f6d9a1b0001',
        NOW(3) - INTERVAL 50 MINUTE, NOW(3) - INTERVAL 60 MINUTE, NOW(3) - INTERVAL 57 MINUTE),
    (2, 2, @demo_show, 'PENDING',   '6f1c1b4e-2a51-4a4e-9a0e-1f6d9a1b0002',
        NOW(3) + INTERVAL 10 MINUTE, NOW(3), NULL),
    (3, 3, @demo_show, 'EXPIRED',   '6f1c1b4e-2a51-4a4e-9a0e-1f6d9a1b0003',
        NOW(3) - INTERVAL 20 MINUTE, NOW(3) - INTERVAL 30 MINUTE, NULL);

INSERT INTO booking_seat (booking_id, seat_id, price)
SELECT b.booking_id, se.seat_id, sp.price
FROM (SELECT 1 AS booking_id, 'H' AS row_label, 5 AS seat_number
      UNION ALL SELECT 1, 'H', 6
      UNION ALL SELECT 2, 'E', 5
      UNION ALL SELECT 2, 'E', 6
      UNION ALL SELECT 2, 'E', 7
      UNION ALL SELECT 3, 'A', 1) AS b
         JOIN seat se ON se.screen_id = 1 AND se.row_label = b.row_label AND se.seat_number = b.seat_number
         JOIN show_price sp ON sp.show_id = @demo_show AND sp.seat_type_id = se.seat_type_id;

-- Current owners in the inventory (booking 3 expired, so A1 stays NULL / free)
UPDATE show_seat ss
    JOIN booking_seat bs ON bs.seat_id = ss.seat_id
SET ss.booking_id = bs.booking_id,
    ss.version    = ss.version + 1
WHERE ss.show_id = @demo_show
  AND bs.booking_id IN (1, 2);

-- ---------------------------------------------------------------- payments
INSERT INTO payment (payment_id, booking_id, gateway, gateway_order_id, gateway_payment_id, amount, status, created_at) VALUES
    (1, 1, 'RAZORPAY', 'order_Q1A2B3C4D5', 'pay_Q9Z8Y7X6W5', 900.00, 'CAPTURED', NOW(3) - INTERVAL 59 MINUTE),
    (2, 2, 'RAZORPAY', 'order_Q1A2B3C4D6', NULL,             750.00, 'CREATED',  NOW(3));

INSERT INTO payment_webhook_event (gateway, event_id, event_type, payment_id, payload, outcome, received_at, processed_at) VALUES
    ('RAZORPAY', 'evt_Qa1b2c3d4e5', 'payment.captured', 1,
     JSON_OBJECT('order_id', 'order_Q1A2B3C4D5', 'payment_id', 'pay_Q9Z8Y7X6W5', 'amount', 90000, 'currency', 'INR'),
     'BOOKING_CONFIRMED', NOW(3) - INTERVAL 57 MINUTE, NOW(3) - INTERVAL 57 MINUTE);
