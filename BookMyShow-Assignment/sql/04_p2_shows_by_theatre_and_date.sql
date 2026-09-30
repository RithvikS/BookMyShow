-- =============================================================================
--  BookMyShow-style Ticketing Backend  |  P2
--  "List all the shows on a given date at a given theatre, with their timings."
--  Run: mysql -u root -p bookmyshow < sql/04_p2_shows_by_theatre_and_date.sql
--
--  Inputs (change these two lines):
--      @theatre_id - the theatre the user opened
--      @show_date  - the date chip the user tapped in the 7-day strip
-- =============================================================================

USE bookmyshow;

SET @theatre_id = 1;
SET @show_date  = CURDATE() + INTERVAL 1 DAY;     -- e.g. DATE('2026-09-29')

-- -----------------------------------------------------------------------------
-- P2 (main answer): one row per show, ordered by movie then time.
--
-- Why "start_time >= @d AND start_time < @d + 1 day" and not DATE(start_time) = @d?
-- Wrapping the column in a function hides it from the index. The half-open
-- range is SARGable: MySQL walks screen(theatre_id) -> shows(screen_id,
-- start_time) with an index range scan and touches only that day's rows.
-- -----------------------------------------------------------------------------
SELECT t.name                                   AS theatre,
       m.title                                  AS movie,
       m.certificate,
       l.name                                   AS language,
       f.name                                   AS format,
       sc.name                                  AS screen,
       s.show_id,
       TIME_FORMAT(s.start_time, '%h:%i %p')    AS show_time,
       s.cancellation_allowed                   AS cancellable
FROM theatre t
         JOIN screen sc     ON sc.theatre_id = t.theatre_id
         JOIN shows s       ON s.screen_id   = sc.screen_id
         JOIN movie m       ON m.movie_id    = s.movie_id
         JOIN language l    ON l.language_id = s.language_id
         JOIN show_format f ON f.format_id   = s.format_id
WHERE t.theatre_id = @theatre_id
  AND s.start_time >= @show_date
  AND s.start_time <  @show_date + INTERVAL 1 DAY
  AND s.status = 'SCHEDULED'
ORDER BY m.title, l.name, f.name, s.start_time;

-- -----------------------------------------------------------------------------
-- P2 (UI shape): exactly what the theatre page renders - one card per
-- movie + language + format with its show timings side by side.
-- -----------------------------------------------------------------------------
SELECT m.title                                                        AS movie,
       m.certificate,
       l.name                                                         AS language,
       f.name                                                         AS format,
       COUNT(*)                                                       AS shows,
       GROUP_CONCAT(TIME_FORMAT(s.start_time, '%h:%i %p')
                    ORDER BY s.start_time SEPARATOR '  |  ')          AS show_timings
FROM screen sc
         JOIN shows s       ON s.screen_id   = sc.screen_id
         JOIN movie m       ON m.movie_id    = s.movie_id
         JOIN language l    ON l.language_id = s.language_id
         JOIN show_format f ON f.format_id   = s.format_id
WHERE sc.theatre_id = @theatre_id
  AND s.start_time >= @show_date
  AND s.start_time <  @show_date + INTERVAL 1 DAY
  AND s.status = 'SCHEDULED'
GROUP BY m.movie_id, m.title, m.certificate, l.name, f.name
ORDER BY m.title, l.name, f.name;

-- -----------------------------------------------------------------------------
-- Supporting query: the 7-day date strip at the top of the theatre page
-- (only dates that actually have at least one bookable show).
-- -----------------------------------------------------------------------------
SELECT DATE(s.start_time)                    AS show_date,
       DATE_FORMAT(s.start_time, '%a %d %b') AS label,
       COUNT(*)                              AS shows
FROM screen sc
         JOIN shows s ON s.screen_id = sc.screen_id
WHERE sc.theatre_id = @theatre_id
  AND s.start_time >= CURDATE()
  AND s.start_time <  CURDATE() + INTERVAL 7 DAY
  AND s.status = 'SCHEDULED'
GROUP BY DATE(s.start_time), DATE_FORMAT(s.start_time, '%a %d %b')
ORDER BY show_date;

-- -----------------------------------------------------------------------------
-- Proof that P2 is index-driven (no full table scan on shows).
-- -----------------------------------------------------------------------------
EXPLAIN
SELECT m.title, s.start_time
FROM screen sc
         JOIN shows s ON s.screen_id = sc.screen_id
         JOIN movie m ON m.movie_id  = s.movie_id
WHERE sc.theatre_id = @theatre_id
  AND s.start_time >= @show_date
  AND s.start_time <  @show_date + INTERVAL 1 DAY
  AND s.status = 'SCHEDULED';
