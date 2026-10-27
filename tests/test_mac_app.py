"""app/ 의 Swift 앱 소스가 .app 으로 묶일 수 있는 모양인지 본다. 실제 빌드와 실행은 macOS에서
   app/build.sh 로 직접 해 봐야 안다.
   python3 tests/test_mac_app.py"""
import os, plistlib

APP = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "app")


def main():
    with open(os.path.join(APP, "Info.plist"), "rb") as f:
        info = plistlib.load(f)
    assert info.get("CFBundlePackageType") == "APPL", "앱 종류(APPL)가 아니다"
    assert os.path.isfile(os.path.join(APP, "AgentHUD.swift")), "소스가 없다"
    assert os.path.isfile(os.path.join(APP, info["CFBundleIconFile"] + ".icns")), "아이콘 파일이 없다"
    assert os.access(os.path.join(APP, "build.sh"), os.X_OK), "build.sh 실행 권한이 없다"
    print("PASS")


if __name__ == "__main__":
    main()
