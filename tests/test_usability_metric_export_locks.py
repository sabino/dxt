"""Actual process and PostgreSQL locks protect native saved metric exports."""
from __future__ import annotations

import fcntl
import hashlib
import json
from pathlib import Path

import pytest

from test_usability_commands import core_runner, native_binary, run_dxt, query, invoke_core
from test_usability_semantics import metric_project, cross_metric_project


@pytest.mark.parametrize('named', [False, True])
def test_saved_export_target_lock_precedes_query_execution_and_releases(cross_metric_project, named):
    project, config, _ = cross_metric_project
    properties = project / 'models/semantic.yml'
    if not named:
        source = properties.read_text().replace('        connection: crm\n','').replace('        source: [analytics, customers]\n','')
        properties.write_text(source)
    flags = ['--connection','warehouse','--allow-movement'] if named else []
    args = ('metric','export','--saved-query','daily_revenue',*flags)
    assert run_dxt(project,*args).returncode == 0
    expected = query(project / 'warehouse.duckdb','select * from reporting.daily_revenue_export order by metric_time__day')
    # A competing process lock does not require opening the destination database.
    directory = Path(str(project / 'warehouse.duckdb') + '.dxt-locks')
    path = directory / hashlib.sha256(b'reporting.daily_revenue_export').hexdigest()
    assert path.exists()
    with path.open('r+') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX | fcntl.LOCK_NB)
        source = properties.read_text()
        if named:
            # An unavailable source would fail if execution preceded locking.
            properties.write_text(source.replace('        source: [analytics, customers]', '        source_query: select id, country from analytics.absent_customers'))
        result = run_dxt(project,*args)
        assert result.returncode != 0
        assert 'CrossDatabaseTargetLocked' in result.stderr
        properties.write_text(source)
        assert query(project / 'warehouse.duckdb','select * from reporting.daily_revenue_export order by metric_time__day') == expected
        # Explain stays available while the destination is locked.
        assert run_dxt(project,'metric','explain','--saved-query','daily_revenue',*flags).returncode == 0
    assert run_dxt(project,*args).returncode == 0
    assert query(project / 'warehouse.duckdb','select * from reporting.daily_revenue_export order by metric_time__day') == expected


@pytest.mark.parametrize('named', [False,True])
def test_postgres_saved_export_uses_transaction_advisory_lock_and_preserves_target(tmp_path,core_runner,named):
    import postgres_fixture as pgserver
    import psycopg2
    with pgserver.get_server(tmp_path / 'postgres-data') as server:
        project = metric_project(tmp_path / 'metric')
        info = server.get_postmaster_info()
        profiles = {'commands': {'target':'dev','outputs':{'dev':{
            'type':'postgres','host':str(info.socket_dir),'port':info.port,'dbname':'postgres',
            'user':'postgres','password':'','schema':'dev','threads':1}}}}
        (project / 'profiles.yml').write_text(json.dumps(profiles))
        if named:
            (project / 'dxt_connections.yml').write_text(json.dumps({'connections':{'warehouse':{'profile':'commands','target':'dev','role':'both'}}}))
        with psycopg2.connect(server.get_uri()) as connection, connection.cursor() as cursor:
            cursor.execute('create schema dev;create table dev.orders(id integer,customer_id integer,amount integer,ordered_at date,status text)')
            cursor.execute("insert into dev.orders values (1,1,10,'2024-01-01','paid'),(2,1,20,'2024-01-03','paid')")
            cursor.execute('create table dev.customers(id integer,country text);insert into dev.customers values(1,\'US\')')
            cursor.execute("create table dev.metricflow_time_spine as select generate_series(date '2024-01-01',date '2024-01-05',interval '1 day')::date date_day")
            cursor.execute('create schema reporting;create table reporting.daily_revenue_export(marker text);insert into reporting.daily_revenue_export values(\'preserved\')')
        assert invoke_core(core_runner,project,'parse').success
        flags = ['--connection','warehouse'] if named else []
        blocker = psycopg2.connect(server.get_uri())
        blocker.autocommit=True
        try:
            with blocker.cursor() as cursor:
                cursor.execute("select pg_advisory_lock(hashtextextended(current_database() || 'reporting.daily_revenue_export',0))")
                cursor.execute("create function dev.fail_export_query() returns boolean language plpgsql as $$ begin raise exception 'export source was executed'; end $$")
                cursor.execute('alter table dev.orders rename to orders_storage')
                cursor.execute('create view dev.orders as select * from dev.orders_storage where dev.fail_export_query()')
            result = run_dxt(project,'metric','export','--saved-query','daily_revenue',*flags)
            assert result.returncode != 0
            assert 'CrossDatabaseTargetLocked' in result.stderr
            with blocker.cursor() as cursor:
                cursor.execute('select * from reporting.daily_revenue_export')
                assert cursor.fetchall() == [('preserved',)]
                cursor.execute('drop view dev.orders;alter table dev.orders_storage rename to orders;drop function dev.fail_export_query()')
                cursor.execute('select pg_advisory_unlock_all()')
            result = run_dxt(project,'metric','export','--saved-query','daily_revenue',*flags)
            assert result.returncode == 0,result.stderr
            with blocker.cursor() as cursor:
                cursor.execute('select * from reporting.daily_revenue_export order by metric_time__day')
                assert [row[1] for row in cursor.fetchall()] == [10,20]
        finally:
            blocker.close()
