"""Pinned PostgreSQL profile aliases and actual held-session policies."""
from pathlib import Path

import pytest
import psycopg2
import yaml

from test_cli import build_dxt
from validate_dbt_artifacts import assert_artifact
from test_usability_configuration import configuration_oracle, configuration_postgres
from test_usability_resource_hooks import setup_pair, rows


def update_profiles(pair, **settings):
    for project in pair.projects:
        path = project / 'profiles.yml'
        profile = yaml.safe_load(path.read_text())
        output = profile['configuration_fixture']['outputs']['dev']
        output.update(settings)
        path.write_text(yaml.safe_dump(profile))


@pytest.mark.parametrize('database_key', ['database', 'dbname'])
@pytest.mark.parametrize('password_key', ['password', 'pass'])
def test_postgres_credential_aliases_target_identity_and_secret_publication(tmp_path, configuration_oracle, configuration_postgres, request, database_key, password_key):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'postgres')
    # A dedicated database makes libpq's implicit default unable to hide dropped credentials.
    database = 'alias_' + ''.join(c for c in tmp_path.name if c.isalnum())[-35:]
    username = database + '_user'
    connection = psycopg2.connect(configuration_postgres.get_uri())
    try:
        connection.autocommit = True
        with connection.cursor() as cursor:
            cursor.execute('create database "' + database + '"')
            cursor.execute('create role "' + username + '" login superuser password %s', ('synthetic-private-profile-password',))
            cursor.execute('show hba_file')
            hba = Path(cursor.fetchone()[0])
            hba.write_text('local ' + database + ' ' + username + ' scram-sha-256\n' + hba.read_text())
            cursor.execute('select pg_reload_conf()')
            assert cursor.fetchone() == (True,)
    finally:
        connection.close()
    for project in pair.projects:
        path = project / 'profiles.yml'
        profile = yaml.safe_load(path.read_text())
        output = profile['configuration_fixture']['outputs']['dev']
        output.pop('dbname')
        output.pop('password')
        output['user'] = username
        output[database_key] = database
        output[password_key] = 'synthetic-private-profile-password'
        path.write_text(yaml.safe_dump(profile))
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table') }}select current_database() as actual_database, '{{ target.database }}' as target_database, '{{ target.dbname }}' as target_alias, '{{ target.password is defined }}' as password_visible, '{{ target.pass is defined }}' as pass_visible")
    manifests = pair.invoke('run')
    for project, manifest in zip(pair.projects, manifests):
        assert_artifact(project / 'target/manifest.json')
        assert_artifact(project / 'target/run_results.json')
        node = manifest['nodes']['model.configuration_fixture.rendered']
        assert node['database'] == database
        with psycopg2.connect(configuration_postgres.get_uri(), dbname=database) as connection:
            with connection.cursor() as cursor:
                cursor.execute('select * from "' + node['schema'] + '".rendered')
                assert cursor.fetchall() == [(database, database, database, 'False', 'False')]
        for artifact in (project / 'target').rglob('*'):
            if artifact.is_file():
                assert b'synthetic-private-profile-password' not in artifact.read_bytes()


@pytest.mark.parametrize('keys', [('database', 'dbname'), ('password', 'pass')])
@pytest.mark.parametrize('same', [True, False])
def test_postgres_credential_alias_collision_matches_core(tmp_path, configuration_oracle, request, keys, same):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'postgres')
    update_profiles(pair, **{keys[0]: 'same', keys[1]: 'same' if same else 'different'})
    pair.write('models/marts/rendered.sql', 'select 1 as id')
    pair.invoke('parse', success=False)
    for project in pair.projects:
        assert not (project / 'target/manifest.json').exists()


def test_postgres_session_policy_applies_to_each_worker(tmp_path, configuration_oracle, configuration_postgres, request):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'postgres')
    suffix = ''.join(c for c in tmp_path.name if c.isalnum())[-25:]
    role = 'profile_role_' + suffix
    schema = 'Profile Schema ' + suffix
    with psycopg2.connect(configuration_postgres.get_uri()) as connection:
        with connection.cursor() as cursor:
            cursor.execute('create role "' + role + '" superuser')
            cursor.execute('create schema "' + schema + '"')
            cursor.execute('create table "' + schema + '".profile_source as select 73 as id')
    update_profiles(pair, role='"' + role + '"', search_path='"' + schema + '",public', application_name="profile's application", threads=3)
    for name in ['rendered', 'second', 'third']:
        pair.write('models/marts/' + name + '.sql', "{{ config(materialized='table') }}select id, current_user::text as active_role, current_setting('search_path') as active_path, current_setting('application_name') as active_application from profile_source")
    pair.invoke('run')
    for name in ['rendered', 'second', 'third']:
        actual, expected = rows(pair, request, 'postgres', 'select * from {schema}.' + name)
        assert actual == expected == [(73, role, '"' + schema + '",public', "profile's application")]


def test_invalid_postgres_role_fails_before_model_mutation(tmp_path, configuration_oracle, request):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'postgres')
    update_profiles(pair, role='dxt_missing_profile_role')
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table') }}select 1 as id")
    pair.invoke('run', success=False)
    assert rows(pair, request, 'postgres', "select count(*) from information_schema.tables where table_schema='{schema}' and table_name='rendered'") == [[(0,)], [(0,)]]

@pytest.mark.parametrize('application', [None, '', 'configured application'])
def test_postgres_optional_application_name_matches_core(tmp_path, configuration_oracle, request, application):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'postgres')
    update_profiles(pair, application_name=application, role=None, search_path=None)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table') }}select current_setting('application_name') as application")
    pair.invoke('run')
    assert rows(pair, request, 'postgres', 'select application from {schema}.rendered') == [[(application or '',)]] * 2
