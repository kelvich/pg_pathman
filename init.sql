/* ------------------------------------------------------------------------
 *
 * init.sql
 *		Creates config table and provides common utility functions
 *
 * Copyright (c) 2015-2016, Postgres Professional
 *
 * ------------------------------------------------------------------------
 */


/*
 * Takes text representation of interval value and checks if it is corresponds
 * to partitioning key. The function throws an error if it fails to convert
 * text to Datum
 */
CREATE OR REPLACE FUNCTION @extschema@.validate_interval_value(
	atttype			OID,
	parttype		INTEGER,
	range_interval	TEXT)
RETURNS BOOL AS 'pg_pathman', 'validate_interval_value'
LANGUAGE C;


/*
 * Pathman config
 *		partrel - regclass (relation type, stored as Oid)
 *		attname - partitioning key
 *		parttype - partitioning type:
 *			1 - HASH
 *			2 - RANGE
 *		range_interval - base interval for RANGE partitioning as string
 */
CREATE TABLE IF NOT EXISTS @extschema@.pathman_config (
	partrel			REGCLASS NOT NULL PRIMARY KEY,
	attname			TEXT NOT NULL,	/* expression */
	parttype		INTEGER NOT NULL,
	range_interval	TEXT,
	expression_p	TEXT,				/* parsed expression (until plan) */
	atttype			OID,				/* expression type */

	/* check for allowed part types */
	CONSTRAINT pathman_config_parttype_check CHECK (parttype IN (1, 2)),

	/* check for correct interval */
	CONSTRAINT pathman_config_interval_check CHECK (@extschema@.validate_interval_value(atttype,
													parttype,
													range_interval))
);


/*
 * Checks that callback function meets specific requirements.
 * Particularly it must have the only JSONB argument and VOID return type.
 *
 * NOTE: this function is used in CHECK CONSTRAINT.
 */
CREATE OR REPLACE FUNCTION @extschema@.validate_part_callback(
	callback		REGPROCEDURE,
	raise_error		BOOL DEFAULT TRUE)
RETURNS BOOL AS 'pg_pathman', 'validate_part_callback_pl'
LANGUAGE C STRICT;


/*
 * Optional parameters for partitioned tables.
 *		partrel - regclass (relation type, stored as Oid)
 *		enable_parent - add parent table to plan
 *		auto - enable automatic partition creation
 *		init_callback - text signature of cb to be executed on partition
 * 						creation
 */
CREATE TABLE IF NOT EXISTS @extschema@.pathman_config_params (
	partrel			REGCLASS NOT NULL PRIMARY KEY,
	enable_parent	BOOLEAN NOT NULL DEFAULT FALSE,
	auto			BOOLEAN NOT NULL DEFAULT TRUE,
	init_callback	TEXT DEFAULT NULL,
	spawn_using_bgw	BOOLEAN NOT NULL DEFAULT FALSE

	/* check callback's signature */
	CHECK (@extschema@.validate_part_callback(CASE WHEN init_callback IS NULL
											  THEN 0::REGPROCEDURE
											  ELSE init_callback::REGPROCEDURE
											  END))
);

GRANT SELECT, INSERT, UPDATE, DELETE
ON @extschema@.pathman_config, @extschema@.pathman_config_params
TO public;

/*
 * Check if current user can alter/drop specified relation
 */
CREATE OR REPLACE FUNCTION @extschema@.check_security_policy(relation regclass)
RETURNS BOOL AS 'pg_pathman', 'check_security_policy' LANGUAGE C STRICT;

/*
 * Row security policy to restrict partitioning operations to owner and superusers only
 */
CREATE POLICY deny_modification ON @extschema@.pathman_config
FOR ALL USING (check_security_policy(partrel));

CREATE POLICY deny_modification ON @extschema@.pathman_config_params
FOR ALL USING (check_security_policy(partrel));

CREATE POLICY allow_select ON @extschema@.pathman_config FOR SELECT USING (true);

CREATE POLICY allow_select ON @extschema@.pathman_config_params FOR SELECT USING (true);

ALTER TABLE @extschema@.pathman_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE @extschema@.pathman_config_params ENABLE ROW LEVEL SECURITY;

/*
 * Invalidate relcache every time someone changes parameters config.
 */
CREATE OR REPLACE FUNCTION @extschema@.pathman_config_params_trigger_func()
RETURNS TRIGGER AS 'pg_pathman', 'pathman_config_params_trigger_func'
LANGUAGE C;

CREATE TRIGGER pathman_config_params_trigger
AFTER INSERT OR UPDATE OR DELETE ON @extschema@.pathman_config_params
FOR EACH ROW EXECUTE PROCEDURE @extschema@.pathman_config_params_trigger_func();

/*
 * Enable dump of config tables with pg_dump.
 */
SELECT pg_catalog.pg_extension_config_dump('@extschema@.pathman_config', '');
SELECT pg_catalog.pg_extension_config_dump('@extschema@.pathman_config_params', '');


/*
 * Add a row describing the optional parameter to pathman_config_params.
 */
CREATE OR REPLACE FUNCTION @extschema@.pathman_set_param(
	relation	REGCLASS,
	param		TEXT,
	value		ANYELEMENT)
RETURNS VOID AS
$$
BEGIN
	EXECUTE format('INSERT INTO @extschema@.pathman_config_params
					(partrel, %1$s) VALUES ($1, $2)
					ON CONFLICT (partrel) DO UPDATE SET %1$s = $2', param)
	USING relation, value;
END
$$
LANGUAGE plpgsql;

/*
 * Include\exclude parent relation in query plan.
 */
CREATE OR REPLACE FUNCTION @extschema@.set_enable_parent(
	relation	REGCLASS,
	value		BOOLEAN)
RETURNS VOID AS
$$
BEGIN
	PERFORM @extschema@.pathman_set_param(relation, 'enable_parent', value);
END
$$
LANGUAGE plpgsql STRICT;

/*
 * Enable\disable automatic partition creation.
 */
CREATE OR REPLACE FUNCTION @extschema@.set_auto(
	relation	REGCLASS,
	value		BOOLEAN)
RETURNS VOID AS
$$
BEGIN
	PERFORM @extschema@.pathman_set_param(relation, 'auto', value);
END
$$
LANGUAGE plpgsql STRICT;

/*
 * Set partition creation callback
 */
CREATE OR REPLACE FUNCTION @extschema@.set_init_callback(
	relation	REGCLASS,
	callback	REGPROCEDURE DEFAULT 0)
RETURNS VOID AS
$$
DECLARE
	regproc_text	TEXT := NULL;

BEGIN

	/* Fetch schema-qualified name of callback */
	IF callback != 0 THEN
		SELECT quote_ident(nspname) || '.' ||
			   quote_ident(proname) || '(' ||
					(SELECT string_agg(x.argtype::REGTYPE::TEXT, ',')
					 FROM unnest(proargtypes) AS x(argtype)) ||
			   ')'
		FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n
		ON n.oid = p.pronamespace
		WHERE p.oid = callback
		INTO regproc_text; /* <= result */
	END IF;

	PERFORM @extschema@.pathman_set_param(relation, 'init_callback', regproc_text);
END
$$
LANGUAGE plpgsql STRICT;

/*
 * Set 'spawn using BGW' option
 */
CREATE OR REPLACE FUNCTION @extschema@.set_spawn_using_bgw(
	relation	REGCLASS,
	value		BOOLEAN)
RETURNS VOID AS
$$
BEGIN
	PERFORM @extschema@.pathman_set_param(relation, 'spawn_using_bgw', value);
END
$$
LANGUAGE plpgsql STRICT;

/*
 * Set (or reset) default interval for auto created partitions
 */
CREATE OR REPLACE FUNCTION @extschema@.set_interval(
	relation		REGCLASS,
	value			ANYELEMENT)
RETURNS VOID AS
$$
DECLARE
	affected	INTEGER;
BEGIN
	UPDATE @extschema@.pathman_config
	SET range_interval = value::text
	WHERE partrel = relation AND parttype = 2;

	/* Check number of affected rows */
	GET DIAGNOSTICS affected = ROW_COUNT;

	IF affected = 0 THEN
		RAISE EXCEPTION 'table "%" is not partitioned by RANGE', relation;
	END IF;
END
$$
LANGUAGE plpgsql;


/*
 * Show all existing parents and partitions.
 */
CREATE OR REPLACE FUNCTION @extschema@.show_partition_list()
RETURNS TABLE (
	parent			REGCLASS,
	partition		REGCLASS,
	parttype		INT4,
	partattr		TEXT,
	range_min		TEXT,
	range_max		TEXT)
AS 'pg_pathman', 'show_partition_list_internal'
LANGUAGE C STRICT;

/*
 * View for show_partition_list().
 */
CREATE OR REPLACE VIEW @extschema@.pathman_partition_list
AS SELECT * FROM @extschema@.show_partition_list();

GRANT SELECT ON @extschema@.pathman_partition_list TO PUBLIC;

/*
 * Show memory usage of pg_pathman's caches.
 */
CREATE OR REPLACE FUNCTION @extschema@.show_cache_stats()
RETURNS TABLE (
	context			TEXT,
	size			INT8,
	used			INT8,
	entries			INT8)
AS 'pg_pathman', 'show_cache_stats_internal'
LANGUAGE C STRICT;

/*
 * View for show_cache_stats().
 */
CREATE OR REPLACE VIEW @extschema@.pathman_cache_stats
AS SELECT * FROM @extschema@.show_cache_stats();

/*
 * Show all existing concurrent partitioning tasks.
 */
CREATE OR REPLACE FUNCTION @extschema@.show_concurrent_part_tasks()
RETURNS TABLE (
	userid		REGROLE,
	pid			INT,
	dbid		OID,
	relid		REGCLASS,
	processed	INT,
	status		TEXT)
AS 'pg_pathman', 'show_concurrent_part_tasks_internal'
LANGUAGE C STRICT;

/*
 * View for show_concurrent_part_tasks().
 */
CREATE OR REPLACE VIEW @extschema@.pathman_concurrent_part_tasks
AS SELECT * FROM @extschema@.show_concurrent_part_tasks();

GRANT SELECT ON @extschema@.pathman_concurrent_part_tasks TO PUBLIC;

/*
 * Partition table using ConcurrentPartWorker.
 */
CREATE OR REPLACE FUNCTION @extschema@.partition_table_concurrently(
	relation		REGCLASS,
	batch_size		INTEGER DEFAULT 1000,
	sleep_time		FLOAT8 DEFAULT 1.0)
RETURNS VOID AS 'pg_pathman', 'partition_table_concurrently'
LANGUAGE C STRICT;

/*
 * Stop concurrent partitioning task.
 */
CREATE OR REPLACE FUNCTION @extschema@.stop_concurrent_part_task(
	relation		REGCLASS)
RETURNS BOOL AS 'pg_pathman', 'stop_concurrent_part_task'
LANGUAGE C STRICT;


/*
 * Copy rows to partitions concurrently.
 */
CREATE OR REPLACE FUNCTION @extschema@._partition_data_concurrent(
	relation		REGCLASS,
	p_min			ANYELEMENT DEFAULT NULL::text,
	p_max			ANYELEMENT DEFAULT NULL::text,
	p_limit			INT DEFAULT NULL,
	OUT p_total		BIGINT)
AS
$$
DECLARE
	v_attr			TEXT;
	v_limit_clause	TEXT := '';
	v_where_clause	TEXT := '';
	ctids			TID[];

BEGIN
	SELECT attname INTO v_attr
	FROM @extschema@.pathman_config WHERE partrel = relation;

	p_total := 0;

	/* Format LIMIT clause if needed */
	IF NOT p_limit IS NULL THEN
		v_limit_clause := format('LIMIT %s', p_limit);
	END IF;

	/* Format WHERE clause if needed */
	IF NOT p_min IS NULL THEN
		v_where_clause := format('%1$s >= $1', v_attr);
	END IF;

	IF NOT p_max IS NULL THEN
		IF NOT p_min IS NULL THEN
			v_where_clause := v_where_clause || ' AND ';
		END IF;
		v_where_clause := v_where_clause || format('%1$s < $2', v_attr);
	END IF;

	IF v_where_clause != '' THEN
		v_where_clause := 'WHERE ' || v_where_clause;
	END IF;

	/* Lock rows and copy data */
	RAISE NOTICE 'Copying data to partitions...';
	EXECUTE format('SELECT array(SELECT ctid FROM ONLY %1$s %2$s %3$s FOR UPDATE NOWAIT)',
				   relation, v_where_clause, v_limit_clause)
	USING p_min, p_max
	INTO ctids;

	EXECUTE format('
		WITH data AS (
			DELETE FROM ONLY %1$s WHERE ctid = ANY($1) RETURNING *)
		INSERT INTO %1$s SELECT * FROM data',
		relation)
	USING ctids;

	/* Get number of inserted rows */
	GET DIAGNOSTICS p_total = ROW_COUNT;
	RETURN;
END
$$
LANGUAGE plpgsql
SET pg_pathman.enable_partitionfilter = on; /* ensures that PartitionFilter is ON */

/*
 * Old school way to distribute rows to partitions.
 */
CREATE OR REPLACE FUNCTION @extschema@.partition_data(
	parent_relid	REGCLASS,
	OUT p_total		BIGINT)
AS
$$
BEGIN
	p_total := 0;

	/* Create partitions and copy rest of the data */
	EXECUTE format('WITH part_data AS (DELETE FROM ONLY %1$s RETURNING *)
					INSERT INTO %1$s SELECT * FROM part_data',
				   parent_relid::TEXT);

	/* Get number of inserted rows */
	GET DIAGNOSTICS p_total = ROW_COUNT;
	RETURN;
END
$$
LANGUAGE plpgsql STRICT
SET pg_pathman.enable_partitionfilter = on; /* ensures that PartitionFilter is ON */

/*
 * Disable pathman partitioning for specified relation.
 */
CREATE OR REPLACE FUNCTION @extschema@.disable_pathman_for(
	parent_relid	REGCLASS)
RETURNS VOID AS
$$
BEGIN
	PERFORM @extschema@.validate_relname(parent_relid);

	/* Delete rows from both config tables */
	DELETE FROM @extschema@.pathman_config WHERE partrel = parent_relid;
	DELETE FROM @extschema@.pathman_config_params WHERE partrel = parent_relid;

	/* Drop triggers on update */
	PERFORM @extschema@.drop_triggers(parent_relid);
END
$$
LANGUAGE plpgsql STRICT;

/*
 * Aggregates several common relation checks before partitioning.
 * Suitable for every partitioning type.
 */
CREATE OR REPLACE FUNCTION @extschema@.common_relation_checks(
	relation		REGCLASS,
	expression		TEXT)
RETURNS BOOLEAN AS
$$
DECLARE
	v_rec			RECORD;
	is_referenced	BOOLEAN;
	rel_persistence	CHAR;

BEGIN
	/* Ignore temporary tables */
	SELECT relpersistence FROM pg_catalog.pg_class
	WHERE oid = relation INTO rel_persistence;

	IF rel_persistence = 't'::CHAR THEN
		RAISE EXCEPTION 'temporary table "%" cannot be partitioned',
						relation::TEXT;
	END IF;

	IF EXISTS (SELECT * FROM @extschema@.pathman_config
			   WHERE partrel = relation) THEN
		RAISE EXCEPTION 'relation "%" has already been partitioned', relation;
	END IF;

	/* Check if there are foreign keys that reference the relation */
	FOR v_rec IN (SELECT * FROM pg_catalog.pg_constraint
				  WHERE confrelid = relation::REGCLASS::OID)
	LOOP
		is_referenced := TRUE;
		RAISE WARNING 'foreign key "%" references relation "%"',
				v_rec.conname, relation;
	END LOOP;

	IF is_referenced THEN
		RAISE EXCEPTION 'relation "%" is referenced from other relations', relation;
	END IF;

	RETURN FALSE;
END
$$
LANGUAGE plpgsql;

/*
 * Returns relname without quotes or something.
 */
CREATE OR REPLACE FUNCTION @extschema@.get_plain_schema_and_relname(
	cls				REGCLASS,
	OUT schema		TEXT,
	OUT relname		TEXT)
AS
$$
BEGIN
	SELECT pg_catalog.pg_class.relnamespace::regnamespace,
		   pg_catalog.pg_class.relname
	FROM pg_catalog.pg_class WHERE oid = cls::oid
	INTO schema, relname;
END
$$
LANGUAGE plpgsql STRICT;

/*
 * DDL trigger that removes entry from pathman_config table.
 */
CREATE OR REPLACE FUNCTION @extschema@.pathman_ddl_trigger_func()
RETURNS event_trigger AS
$$
DECLARE
	obj				record;
	pg_class_oid	oid;
	relids			regclass[];
BEGIN
	pg_class_oid = 'pg_catalog.pg_class'::regclass;

	/* Find relids to remove from config */
	SELECT array_agg(cfg.partrel) INTO relids
	FROM pg_event_trigger_dropped_objects() AS events
	JOIN @extschema@.pathman_config AS cfg ON cfg.partrel::oid = events.objid
	WHERE events.classid = pg_class_oid AND events.objsubid = 0;

	/* Cleanup pathman_config */
	DELETE FROM @extschema@.pathman_config WHERE partrel = ANY(relids);

	/* Cleanup params table too */
	DELETE FROM @extschema@.pathman_config_params WHERE partrel = ANY(relids);
END
$$
LANGUAGE plpgsql;

/*
 * Drop triggers
 */
CREATE OR REPLACE FUNCTION @extschema@.drop_triggers(
	parent_relid	REGCLASS)
RETURNS VOID AS
$$
DECLARE
	triggername	TEXT;
	rec			RECORD;

BEGIN
	triggername := @extschema@.build_update_trigger_name(parent_relid);

	/* Drop trigger for each partition if exists */
	FOR rec IN (SELECT pg_catalog.pg_inherits.* FROM pg_catalog.pg_inherits
				JOIN pg_catalog.pg_trigger ON inhrelid = tgrelid
				WHERE inhparent = parent_relid AND tgname = triggername)
	LOOP
		EXECUTE format('DROP TRIGGER IF EXISTS %s ON %s',
					   triggername,
					   rec.inhrelid::REGCLASS::TEXT);
	END LOOP;

	/* Drop trigger on parent */
	IF EXISTS (SELECT * FROM pg_catalog.pg_trigger
			   WHERE tgname = triggername AND tgrelid = parent_relid)
	THEN
		EXECUTE format('DROP TRIGGER IF EXISTS %s ON %s',
					   triggername,
					   parent_relid::TEXT);
	END IF;
END
$$ LANGUAGE plpgsql STRICT;

/*
 * Drop partitions. If delete_data set to TRUE, partitions
 * will be dropped with all the data.
 */
CREATE OR REPLACE FUNCTION @extschema@.drop_partitions(
	parent_relid	REGCLASS,
	delete_data		BOOLEAN DEFAULT FALSE)
RETURNS INTEGER AS
$$
DECLARE
	v_rec			RECORD;
	v_rows			BIGINT;
	v_part_count	INTEGER := 0;
	conf_num		INTEGER;
	v_relkind		CHAR;

BEGIN
	PERFORM @extschema@.validate_relname(parent_relid);

	/* Acquire data modification lock */
	PERFORM @extschema@.prevent_relation_modification(parent_relid);

	/* First, drop all triggers */
	PERFORM @extschema@.drop_triggers(parent_relid);

	SELECT count(*) FROM @extschema@.pathman_config
	WHERE partrel = parent_relid INTO conf_num;

	IF conf_num = 0 THEN
		RAISE EXCEPTION 'relation "%" has no partitions', parent_relid::TEXT;
	END IF;

	FOR v_rec IN (SELECT inhrelid::REGCLASS AS tbl
				  FROM pg_catalog.pg_inherits
				  WHERE inhparent::regclass = parent_relid
				  ORDER BY inhrelid ASC)
	LOOP
		IF NOT delete_data THEN
			EXECUTE format('INSERT INTO %s SELECT * FROM %s',
							parent_relid::TEXT,
							v_rec.tbl::TEXT);
			GET DIAGNOSTICS v_rows = ROW_COUNT;

			/* Show number of copied rows */
			RAISE NOTICE '% rows copied from %', v_rows, v_rec.tbl::TEXT;
		END IF;

		SELECT relkind FROM pg_catalog.pg_class
		WHERE oid = v_rec.tbl
		INTO v_relkind;

		PERFORM @extschema@.prepare_partition_drop(parent_relid, v_rec.tbl);

		/*
		 * Determine the kind of child relation. It can be either a regular
		 * table (r) or a foreign table (f). Depending on relkind we use
		 * DROP TABLE or DROP FOREIGN TABLE.
		 */
		IF v_relkind = 'f' THEN
			EXECUTE format('DROP FOREIGN TABLE %s', v_rec.tbl::TEXT);
		ELSE
			EXECUTE format('DROP TABLE %s', v_rec.tbl::TEXT);
		END IF;

		v_part_count := v_part_count + 1;
	END LOOP;

	/* Finally delete both config entries */
	DELETE FROM @extschema@.pathman_config WHERE partrel = parent_relid;
	DELETE FROM @extschema@.pathman_config_params WHERE partrel = parent_relid;

	RETURN v_part_count;
END
$$ LANGUAGE plpgsql
SET pg_pathman.enable_partitionfilter = off; /* ensures that PartitionFilter is OFF */


/*
 * Copy all of parent's foreign keys.
 */
CREATE OR REPLACE FUNCTION @extschema@.copy_foreign_keys(
	parent_relid	REGCLASS,
	partition_relid	REGCLASS)
RETURNS VOID AS
$$
DECLARE
	rec		RECORD;

BEGIN
	PERFORM @extschema@.validate_relname(parent_relid);
	PERFORM @extschema@.validate_relname(partition_relid);

	FOR rec IN (SELECT oid as conid FROM pg_catalog.pg_constraint
				WHERE conrelid = parent_relid AND contype = 'f')
	LOOP
		EXECUTE format('ALTER TABLE %s ADD %s',
					   partition_relid::TEXT,
					   pg_catalog.pg_get_constraintdef(rec.conid));
	END LOOP;
END
$$ LANGUAGE plpgsql STRICT;


/*
 * Set new relname, schema and tablespace
 */
CREATE OR REPLACE FUNCTION @extschema@.alter_partition(
	relation		REGCLASS,
	new_name		TEXT,
	new_schema		REGNAMESPACE,
	new_tablespace	TEXT)
RETURNS VOID AS
$$
DECLARE
	orig_name	TEXT;
	orig_schema	OID;

BEGIN
	SELECT relname, relnamespace FROM pg_class
	WHERE oid = relation
	INTO orig_name, orig_schema;

	/* Alter table name */
	IF new_name != orig_name THEN
		EXECUTE format('ALTER TABLE %s RENAME TO %s', relation, new_name);
	END IF;

	/* Alter table schema */
	IF new_schema != orig_schema THEN
		EXECUTE format('ALTER TABLE %s SET SCHEMA %s', relation, new_schema);
	END IF;

	/* Move to another tablespace */
	IF NOT new_tablespace IS NULL THEN
		EXECUTE format('ALTER TABLE %s SET TABLESPACE %s', relation, new_tablespace);
	END IF;
END
$$ LANGUAGE plpgsql;


/*
 * Function for UPDATE triggers.
 */
CREATE OR REPLACE FUNCTION @extschema@.pathman_update_trigger_func()
RETURNS TRIGGER AS 'pg_pathman', 'pathman_update_trigger_func'
LANGUAGE C STRICT;

/*
 * Creates UPDATE triggers.
 */
CREATE OR REPLACE FUNCTION @extschema@.create_update_triggers(
	parent_relid	REGCLASS)
RETURNS VOID AS 'pg_pathman', 'create_update_triggers'
LANGUAGE C STRICT;

/*
 * Creates single UPDATE trigger.
 */
CREATE OR REPLACE FUNCTION @extschema@.create_single_update_trigger(
	parent_relid	REGCLASS,
	partition_relid	REGCLASS)
RETURNS VOID AS 'pg_pathman', 'create_single_update_trigger'
LANGUAGE C STRICT;

/*
 * Check if relation has pg_pathman's UPDATE trigger.
 */
CREATE OR REPLACE FUNCTION @extschema@.has_update_trigger(
	parent_relid	REGCLASS)
RETURNS BOOL AS 'pg_pathman', 'has_update_trigger'
LANGUAGE C STRICT;


/*
 * Partitioning key
 */
CREATE OR REPLACE FUNCTION @extschema@.get_partition_key(
	relid	REGCLASS)
RETURNS TEXT AS
$$
	SELECT attname FROM pathman_config WHERE partrel = relid;
$$
LANGUAGE sql STRICT;


/*
 * Create DDL trigger to call pathman_ddl_trigger_func().
 */
CREATE EVENT TRIGGER pathman_ddl_trigger
ON sql_drop
EXECUTE PROCEDURE @extschema@.pathman_ddl_trigger_func();


/*
 * Get number of partitions managed by pg_pathman.
 */
CREATE OR REPLACE FUNCTION @extschema@.get_number_of_partitions(
	parent_relid		REGCLASS)
RETURNS INT4 AS 'pg_pathman', 'get_number_of_partitions_pl'
LANGUAGE C STRICT;

/*
 * Get parent of pg_pathman's partition.
 */
CREATE OR REPLACE FUNCTION @extschema@.get_parent_of_partition(
	partition_relid		REGCLASS)
RETURNS REGCLASS AS 'pg_pathman', 'get_parent_of_partition_pl'
LANGUAGE C STRICT;

/*
 * Extract basic type of a domain.
 */
CREATE OR REPLACE FUNCTION @extschema@.get_base_type(
	typid	REGTYPE)
RETURNS REGTYPE AS 'pg_pathman', 'get_base_type_pl'
LANGUAGE C STRICT;

/*
 * Return partition key type
 */
CREATE OR REPLACE FUNCTION @extschema@.get_partition_key_type(
	relid	REGCLASS)
RETURNS REGTYPE AS 'pg_pathman', 'get_partition_key_type'
LANGUAGE C STRICT;

/*
 * Return tablespace name for specified relation.
 */
CREATE OR REPLACE FUNCTION @extschema@.get_tablespace(
	relid	REGCLASS)
RETURNS TEXT AS 'pg_pathman', 'get_tablespace_pl'
LANGUAGE C STRICT;


/*
 * Check that relation exists.
 */
CREATE OR REPLACE FUNCTION @extschema@.validate_relname(
	relid	REGCLASS)
RETURNS VOID AS 'pg_pathman', 'validate_relname'
LANGUAGE C;

/*
 * Check if regclass is date or timestamp.
 */
CREATE OR REPLACE FUNCTION @extschema@.is_date_type(
	typid	REGTYPE)
RETURNS BOOLEAN AS 'pg_pathman', 'is_date_type'
LANGUAGE C STRICT;

/*
 * Check if TYPE supports the specified operator.
 */
CREATE OR REPLACE FUNCTION @extschema@.is_operator_supported(
	type_oid	REGTYPE,
	opname		TEXT)
RETURNS BOOLEAN AS 'pg_pathman', 'is_operator_supported'
LANGUAGE C STRICT;

/*
 * Check if tuple from first relation can be converted to fit the second one.
 */
CREATE OR REPLACE FUNCTION @extschema@.is_tuple_convertible(
	relation1	REGCLASS,
	relation2	REGCLASS)
RETURNS BOOL AS 'pg_pathman', 'is_tuple_convertible'
LANGUAGE C STRICT;


/*
 * Build check constraint name for a specified relation's column.
 */
CREATE OR REPLACE FUNCTION @extschema@.build_check_constraint_name(
	partition_relid	REGCLASS)
RETURNS TEXT AS 'pg_pathman', 'build_check_constraint_name'
LANGUAGE C STRICT;

/*
 * Build UPDATE trigger's name.
 */
CREATE OR REPLACE FUNCTION @extschema@.build_update_trigger_name(
	relid			REGCLASS)
RETURNS TEXT AS 'pg_pathman', 'build_update_trigger_name'
LANGUAGE C STRICT;

/*
 * Buld UPDATE trigger function's name.
 */
CREATE OR REPLACE FUNCTION @extschema@.build_update_trigger_func_name(
	relid			REGCLASS)
RETURNS TEXT AS 'pg_pathman', 'build_update_trigger_func_name'
LANGUAGE C STRICT;


/*
 * Add record to pathman_config. If parttype if not specified then determine
 * partitioning type.
 */
CREATE OR REPLACE FUNCTION @extschema@.add_to_pathman_config(
	parent_relid		REGCLASS,
	expression			TEXT,
	range_interval		TEXT DEFAULT NULL,
	parttype			INT4 DEFAULT 0
)
RETURNS BOOLEAN AS 'pg_pathman', 'add_to_pathman_config'
LANGUAGE C;


/*
 * Lock partitioned relation to restrict concurrent
 * modification of partitioning scheme.
 */
CREATE OR REPLACE FUNCTION @extschema@.lock_partitioned_relation(
	parent_relid	REGCLASS)
RETURNS VOID AS 'pg_pathman', 'lock_partitioned_relation'
LANGUAGE C STRICT;

/*
 * Lock relation to restrict concurrent modification of data.
 */
CREATE OR REPLACE FUNCTION @extschema@.prevent_relation_modification(
	parent_relid	REGCLASS)
RETURNS VOID AS 'pg_pathman', 'prevent_relation_modification'
LANGUAGE C STRICT;


/*
 * Invoke init_callback on RANGE partition.
 */
CREATE OR REPLACE FUNCTION @extschema@.invoke_on_partition_created_callback(
	parent_relid	REGCLASS,
	partition_relid	REGCLASS,
	init_callback	REGPROCEDURE,
	start_value		ANYELEMENT,
	end_value		ANYELEMENT)
RETURNS VOID AS 'pg_pathman', 'invoke_on_partition_created_callback'
LANGUAGE C;

/*
 * Invoke init_callback on HASH partition.
 */
CREATE OR REPLACE FUNCTION @extschema@.invoke_on_partition_created_callback(
	parent_relid	REGCLASS,
	partition_relid	REGCLASS,
	init_callback	REGPROCEDURE)
RETURNS VOID AS 'pg_pathman', 'invoke_on_partition_created_callback'
LANGUAGE C;


/*
 * DEBUG: Place this inside some plpgsql fuction and set breakpoint.
 */
CREATE OR REPLACE FUNCTION @extschema@.debug_capture()
RETURNS VOID AS 'pg_pathman', 'debug_capture'
LANGUAGE C STRICT;

/*
 * Referential integrity funcs and triggers
 */
CREATE OR REPLACE FUNCTION @extschema@.create_foreign_key(
	fk_table	REGCLASS,
	fk_attr		TEXT,
	pk_table	REGCLASS)
RETURNS VOID AS 'pg_pathman', 'create_foreign_key'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION @extschema@.prepare_partition_drop(
	parent		REGCLASS,
	partition	REGCLASS)
RETURNS VOID AS 'pg_pathman', 'prepare_partition_drop'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION @extschema@.pathman_fkey_check_ins()
RETURNS TRIGGER AS 'pg_pathman', 'pathman_fkey_check_ins'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION @extschema@.pathman_fkey_check_upd()
RETURNS TRIGGER AS 'pg_pathman', 'pathman_fkey_check_upd'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION @extschema@.pathman_fkey_restrict_del()
RETURNS TRIGGER AS 'pg_pathman', 'pathman_fkey_restrict_del'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION @extschema@.pathman_fkey_restrict_upd()
RETURNS TRIGGER AS 'pg_pathman', 'pathman_fkey_restrict_upd'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION @extschema@.get_pathman_lib_version()
RETURNS CSTRING AS 'pg_pathman', 'get_pathman_lib_version'
LANGUAGE C STRICT;
