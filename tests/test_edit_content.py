"""화면에서 지침을 고치는 저장 경로와 플러그인 변경 요청의 입구 검사를 본다.
   python3 tests/test_edit_content.py"""
import importlib.util, os, shutil, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("hud", os.path.join(ROOT, "server.py"))
hud = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hud)


def main():
    tmp = tempfile.mkdtemp()
    try:
        f = os.path.join(tmp, "CLAUDE.md")
        open(f, "w").write("old")
        assert hud.save_content(f, "new")[0] is False, "목록에 없는 경로를 썼다"
        hud.READABLE_PATHS.add(f)
        assert hud.save_content(f, "new") == (True, "") and open(f).read() == "new"

        # CRLF 파일은 CRLF로 돌려 쓴다
        open(f, "wb").write(b"a\r\nb\r\n")
        hud.save_content(f, "x\ny\n")
        assert open(f, "rb").read() == b"x\r\ny\r\n"

        # 링크는 지키고 가리키는 파일을 고친다
        link = os.path.join(tmp, "link.md")
        os.symlink(f, link)
        hud.READABLE_PATHS.add(link)
        hud.save_content(link, "via link")
        assert os.path.islink(link) and open(f, "rb").read() == b"via link"

        # 없는 파일은 '만들 수 있다고 알린' 자리에만 만든다
        new = os.path.join(tmp, "AGENTS.md")
        assert hud.save_content(new, "hi")[0] is False
        hud.CREATABLE_PATHS.add(new)
        assert hud.save_content(new, "hi")[0] and open(new).read() == "hi" and new not in hud.CREATABLE_PATHS

        # 너무 큰 글, 플러그인 폴더는 막는다
        assert not hud.save_content(f, "x" * (hud.EDIT_LIMIT + 1))[0]
        plug = os.path.join(hud.CLAUDE_DIR, "plugins", "cache", "x", "SKILL.md")
        hud.READABLE_PATHS.add(plug)
        assert not hud.save_content(plug, "x")[0]

        # 플러그인 요청: 이상한 이름·범위는 claude를 부르기 전에 거절한다
        for args in [("install", "a;rm -rf /@m", "user"), ("install", "a@m", "project"), ("uninstall", "a@m", "global"),
                     ("install", "a@m", "user")]:  # 마지막: 카탈로그에 없는 플러그인
            assert hud.plugin_change(*args, None)[0] is False, args
        # 그룹 저장: 이름 없음, 모르는 플러그인·스킬은 디스크를 건드리기 전에 거절한다
        assert not hud.save_group("", ["a@m"], [])[0]
        assert not hud.save_group("g", ["nope@nope"], [])[0]
        assert not hud.save_group("g", [], ["no-such-skill"])[0]
        print("PASS")
    finally:
        shutil.rmtree(tmp)


if __name__ == "__main__":
    main()
