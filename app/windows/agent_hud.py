"""Agent HUD 윈도우 앱. 맥의 app/mac/AgentHUD.swift와 같은 일을 한다: 창(WebView2)은 기존 대시보드를
그대로 쓰고, 엔진(server.py)은 같은 프로세스의 스레드로 띄운다. 파이썬과 함께 exe로 묶이므로 설치할 것이 없다.
빌드는 .github/workflows/windows.yml."""
import ctypes, os, threading, time, winreg

import webview

import server

URL = f"http://127.0.0.1:{server.PORT}"
KOREAN = ctypes.windll.kernel32.GetUserDefaultUILanguage() & 0x3FF == 0x12
tr = lambda en, ko: ko if KOREAN else en


def dark():
    try:
        key = winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")
        return winreg.QueryValueEx(key, "AppsUseLightTheme")[0] == 0
    except OSError:
        return False


# 대시보드 CSS의 --bg와 같은 색. 페이지가 그려지기 전에도 창이 흰 번쩍임 없이 같은 색이다.
BG, FG = ("#14150f", "#8f9284") if dark() else ("#eeefe9", "#6c6e63")  # --bg, --dim


def page(body):
    return f"""<!doctype html><meta charset="utf-8"><style>
html{{height:100%;display:grid;place-items:center;background:{BG};color:{FG};font:14px "Segoe UI",sans-serif;text-align:center}}
.spin{{width:26px;height:26px;border:3px solid {FG}33;border-top-color:{FG};border-radius:50%;animation:r .8s linear infinite}}
@keyframes r{{to{{transform:rotate(1turn)}}}} button{{font:inherit;margin-top:12px;padding:4px 14px}}</style>{body}"""


class Api:
    # 폴더 추가: 서버를 거치지 않고 네이티브 폴더 창을 바로 띄운다. 취소하면 빈 문자열.
    def pick_folder(self):
        picked = window.create_file_dialog(webview.FileDialog.FOLDER)
        return picked[0] if picked else ""

    def retry(self):
        window.load_html(page('<div class="spin"></div>'))
        boot()


engine = None


def boot():
    """엔진이 없으면 띄우고, 응답하면 대시보드를 연다. 이미 떠 있는 대시보드(세션 훅이 띄운 것 등)가 있으면
    엔진은 그쪽에 넘기고 끝난다."""
    global engine
    if not (engine and engine.is_alive()):
        os.environ["AGENT_HUD_NO_BROWSER"] = "1"  # 엔진이 시작하며 지운다
        engine = threading.Thread(target=server.main, daemon=True)
        engine.start()
    # 횟수가 아니라 시각으로 끊는다. 윈도우는 닫힌 포트에 한 번 묻는 데만 1초쯤 걸린다.
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        time.sleep(0.05)
        if server.hud_alive(server.PORT):
            return window.load_url(URL)
    window.load_html(page(
        "<div>" + tr(f"The dashboard did not start. Is another program using port {server.PORT}?",
                     f"대시보드가 시작되지 않았습니다. 포트 {server.PORT}를 다른 프로그램이 쓰고 있지 않은지 확인해 주십시오.")
        + f'<br><button onclick="pywebview.api.retry()">{tr("Retry", "다시 시도")}</button></div>'))


server.PROJECT_DIR = server.HOME  # 앱의 작업 폴더는 프로젝트가 아니다. HOME은 목록에 넣지 않는다
window = webview.create_window("Agent HUD", html=page('<div class="spin"></div>'), js_api=Api(),
                               width=1180, height=820, min_size=(760, 520), background_color=BG, text_select=True)
# private_mode를 끄지 않으면 갱신 주기 같은 화면 설정(localStorage)이 창을 닫을 때마다 사라진다.
webview.start(boot, private_mode=False, storage_path=os.path.join(server.TOOL_DIR, "webview"))
