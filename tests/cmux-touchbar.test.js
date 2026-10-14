// Value: protects=a temp app bundle compiles and its behavioral and AppKit button checks pass; fails_when=compile or self-test regresses; why_new=README documented the check without an enforced command; seam=none; no_claim=live cmux close flow and physical Touch Bar rendering
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "..");

test("compiles a temporary app bundle and passes its regression self-test", () => {
  assert.ok(fs.existsSync(path.join(root, "main.swift")));

  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-touchbar-test-"));
  const app = path.join(tempRoot, "cmux Touch Bar.app");
  const contents = path.join(app, "Contents");
  const resources = path.join(contents, "Resources");
  const executable = path.join(contents, "MacOS", "cmux-touchbar");
  const bundleId = `local.cmux-touchbar.test.${path.basename(tempRoot).split("-").pop()}`;

  try {
    fs.mkdirSync(path.dirname(executable), { recursive: true });
    fs.mkdirSync(resources, { recursive: true });
    for (const resource of [
      ["codex.svg", path.join(root, "codex.svg")],
      ["claude.svg", path.join(root, "claude.svg")],
      ["AppIcon.icns", "/Applications/cmux.app/Contents/Resources/AppIcon.icns"],
    ]) {
      fs.copyFileSync(resource[1], path.join(resources, resource[0]));
    }
    fs.writeFileSync(path.join(contents, "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>cmux-touchbar</string>
<key>CFBundleIdentifier</key><string>${bundleId}</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleName</key><string>cmux Touch Bar</string>
<key>CFBundleDisplayName</key><string>cmux Touch Bar</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>`);

    const bridge = path.join(tempRoot, "TouchBarBridge.o");
    const objc = spawnSync("xcrun", ["clang", "-fobjc-arc", "-c", "TouchBarBridge.m", "-o", bridge], { cwd: root, encoding: "utf8" });
    assert.equal(objc.status, 0, `${objc.stdout}\n${objc.stderr}`);

    const build = spawnSync("xcrun", ["swiftc", "main.swift", "CodexLifecycle.swift", bridge,
      "-import-objc-header", "TouchBarBridge.h", "-framework", "AppKit", "-o", executable], { cwd: root, encoding: "utf8" });
    assert.equal(build.status, 0, `${build.stdout}\n${build.stderr}`);
    const sign = spawnSync("codesign", ["--force", "--sign", "-", app], { encoding: "utf8" });
    assert.equal(sign.status, 0, `${sign.stdout}\n${sign.stderr}`);

    const result = spawnSync(executable, ["--self-test"], { encoding: "utf8" });
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}\n${result.error || ""}\nsignal=${result.signal || "none"}`);
    assert.match(result.stdout, /PASS:/);
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});
