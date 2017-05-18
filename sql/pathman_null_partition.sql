\set VERBOSITY terse

SET search_path = 'public';
CREATE EXTENSION pg_pathman;
CREATE SCHEMA test_nulls;

/* hash */
CREATE TABLE test_nulls.hash_rel (
	id		SERIAL PRIMARY KEY,
	value	INTEGER
);
INSERT INTO test_nulls.hash_rel (value)
	SELECT val FROM generate_series(1, 5) val;
SELECT create_hash_partitions('test_nulls.hash_rel', 'value', 3);

/* test creating null partition */
SELECT * FROM pathman_partition_list ORDER BY partition;
INSERT INTO test_nulls.hash_rel (value) VALUES (NULL);
SELECT * FROM pathman_partition_list ORDER BY partition;

EXPLAIN (COSTS OFF) SELECT tableoid::REGCLASS, value
		FROM test_nulls.hash_rel WHERE value IS NULL;
SELECT tableoid::REGCLASS, value FROM test_nulls.hash_rel WHERE value IS NULL;

EXPLAIN (COSTS OFF) SELECT tableoid::REGCLASS, value
		FROM test_nulls.hash_rel WHERE value IS NOT NULL;

EXPLAIN (COSTS OFF) SELECT tableoid::REGCLASS, value
		FROM test_nulls.hash_rel WHERE value IS NOT NULL AND value = 4;

DROP TABLE test_nulls.hash_rel CASCADE;

/* range */
CREATE TABLE test_nulls.range_rel (
	id	SERIAL PRIMARY KEY,
	dt	TIMESTAMP,
	txt	TEXT);
CREATE INDEX ON test_nulls.range_rel (dt);
INSERT INTO test_nulls.range_rel (dt, txt)
SELECT g, md5(g::TEXT)
	FROM generate_series('2015-01-01', '2015-04-30', '1 day'::interval) as g;
SELECT create_range_partitions('test_nulls.range_rel', 'dt', '2015-01-01'::DATE,
	'1 month'::INTERVAL);

/* test creating null partition */
SELECT * FROM pathman_partition_list ORDER BY partition;
INSERT INTO test_nulls.range_rel (dt, txt) VALUES (NULL, 'null');
SELECT * FROM pathman_partition_list ORDER BY partition;

EXPLAIN (COSTS OFF) SELECT tableoid::REGCLASS, dt
				    FROM test_nulls.range_rel WHERE dt IS NULL;
SELECT tableoid::REGCLASS, dt FROM test_nulls.range_rel WHERE dt IS NULL;

EXPLAIN (COSTS OFF) SELECT tableoid::REGCLASS, dt
				    FROM test_nulls.range_rel WHERE dt IS NOT NULL;

EXPLAIN (COSTS OFF) SELECT tableoid::REGCLASS, dt
				    FROM test_nulls.range_rel WHERE dt IS NOT NULL AND dt > '2015-03-01'::DATE;

EXPLAIN (COSTS OFF) SELECT tableoid::REGCLASS, dt
				    FROM test_nulls.range_rel WHERE dt IS NOT NULL OR dt > '2015-03-01'::DATE;

EXPLAIN (COSTS OFF) SELECT tableoid::REGCLASS, dt
				    FROM test_nulls.range_rel WHERE dt IS NULL OR dt > '2015-03-01'::DATE;

EXPLAIN (COSTS OFF) SELECT tableoid::REGCLASS, dt
				    FROM test_nulls.range_rel WHERE dt IS NULL AND dt > '2015-03-01'::DATE;

DROP SCHEMA test_nulls CASCADE;
DROP EXTENSION pg_pathman CASCADE;
