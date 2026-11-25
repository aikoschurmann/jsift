import threading

import pytest

import jsift

DATA = (
    '{"name": "Alice", "age": 25, "level": "error", "user": {"id": 1}}\n'
    '{"name": "Bob", "age": 40, "level": "info", "user": {"id": 2}}\n'
    '{"name": "Cara", "age": 31, "level": "error", "user": {"id": 3}}\n'
)


@pytest.fixture
def jsonl_file(tmp_path):
    path = tmp_path / "in.jsonl"
    path.write_text(DATA)
    return path


def test_version():
    assert jsift.__version__.count(".") == 2


def test_search_data():
    rows = jsift.search("level eq error", data=DATA)
    assert [r["name"] for r in rows] == ["Alice", "Cara"]


def test_search_file_matches_data(jsonl_file):
    for query in ["level eq error", "age gt 30", "user.id in 1,2", "NOT level eq error"]:
        assert jsift.search(query, file=jsonl_file) == jsift.search(query, data=DATA)


def test_search_lines_raw():
    assert jsift.search_lines("name eq Bob", data=DATA.encode()) == [DATA.splitlines()[1].encode()]


def test_query_as_token_list():
    assert len(jsift.search(["level", "eq", "error", "AND", "age", "lt", "30"], data=DATA)) == 1


def test_count():
    assert jsift.count("level eq error", data=DATA) == 2
    assert jsift.count(data=DATA) == 3


def test_limit():
    assert len(jsift.search("level eq error", data=DATA, limit=1)) == 1
    assert jsift.search("level eq error", data=DATA, limit=0) == []


def test_select():
    assert jsift.select("name,user.id WHERE age gt 30", data=DATA) == [
        {"name": "Bob", "user.id": 2},
        {"name": "Cara", "user.id": 3},
    ]


def test_aggregation():
    (row,) = jsift.search("SELECT sum:age,count:name", data=DATA)
    assert row == {"sum:age": 96.0, "count:name": 3}


def test_run_tsv_header():
    result = jsift.run("SELECT name,age WHERE level eq error", data=DATA, header=True)
    assert result.matched == 2
    assert result.output == b"name\tage\nAlice\t25\nCara\t31\n"


def test_no_match():
    assert jsift.search("level eq debug", data=DATA) == []


def test_empty_input():
    assert jsift.search("level eq error", data=b"") == []


def test_invalid_query():
    with pytest.raises(jsift.JsiftError, match="unknown operator"):
        jsift.search("level zz error", data=DATA)
    with pytest.raises(jsift.JsiftError, match="numeric"):
        jsift.search("age gt abc", data=DATA)


def test_missing_file(tmp_path):
    with pytest.raises(jsift.JsiftError, match="no such file"):
        jsift.search("a exists", file=tmp_path / "nope.jsonl")


def test_file_option_rejected():
    with pytest.raises(jsift.JsiftError):
        jsift.run("--file x a exists", data=DATA)


def test_needs_exactly_one_input(jsonl_file):
    with pytest.raises(TypeError):
        jsift.search("a exists")
    with pytest.raises(TypeError):
        jsift.search("a exists", file=jsonl_file, data=DATA)


def test_threads(jsonl_file):
    results = []

    def work():
        results.append(jsift.count("level eq error", file=jsonl_file))

    threads = [threading.Thread(target=work) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert results == [2] * 8


def test_large_input():
    big = DATA * 50_000
    assert jsift.count("level eq error", data=big) == 100_000
