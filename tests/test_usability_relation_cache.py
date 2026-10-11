"""Real native relation metadata hits and safe invalidation across workers."""
import json
import pytest
from test_usability_adapters import driver, duckdb_environment, postgres_fixture, invoke, decoded

@pytest.mark.parametrize('adapter',['duckdb','postgres'])
@pytest.mark.parametrize('mode',['cache','cache-parallel'])
def test_native_shared_cache_on_actual_databases(driver,tmp_path,request,adapter,mode):
    environment=(request.getfixturevalue('duckdb_environment') if adapter=='duckdb' else request.getfixturevalue('postgres_fixture')[1])
    stats=decoded(invoke(driver,adapter,mode,tmp_path/'cache.duckdb',environment))
    assert stats['misses']>0 and stats['invalidations']>0
    if mode=='cache':
        assert stats['hits']>=4 and stats['warm_queries']==1
    else:
        assert stats['invalidations']>=4*8*3*2
