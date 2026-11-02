#!/bin/bash
# Compiles TelegramCastLocalServer for macOS and exercises it over real HTTP with curl.
# Needs no simulator, no Cast device and no Bazel. Exit status 1 on any failure.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap '[ -n "${SERVER:-}" ] && kill "$SERVER" 2>/dev/null; rm -rf "$WORK"' EXIT
cd "$WORK"
FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected $3, got $2)"; fi; }

cat > main.swift <<'EOF'
import Foundation
final class FileSource: TelegramCastByteSource {
    let contentType = "video/mp4"
    let size: Int64
    private let handle: FileHandle
    private let lock = NSLock()
    init(_ path: String) {
        self.handle = FileHandle(forReadingAtPath: path)!
        self.size = (try! FileManager.default.attributesOfItem(atPath: path)[.size] as! NSNumber).int64Value
    }
    func read(range: Range<Int64>, completion: @escaping (Data?) -> Void) -> () -> Void {
        DispatchQueue.global().async {
            self.lock.lock()
            self.handle.seek(toFileOffset: UInt64(range.lowerBound))
            let data = self.handle.readData(ofLength: range.count)
            self.lock.unlock()
            completion(data)
        }
        return {}
    }
}
let parserCases: [(String, TelegramCastHTTPRange)] = [
    ("bytes=0-0", .partial(0 ..< 1)), ("bytes=2-", .partial(2 ..< 10)), ("bytes=-3", .partial(7 ..< 10)),
    ("bytes=-30", .partial(0 ..< 10)), ("bytes=5-99", .partial(5 ..< 10)), ("bytes=10-", .unsatisfiable),
    ("bytes=-0", .unsatisfiable), ("bytes=0-1,3-4", .full), ("items=0-1", .full), ("bytes=5-2", .full), ("bytes=a-b", .full)
]
for (header, expected) in parserCases where TelegramCastHTTPRange.parse(header: header, size: 10) != expected {
    print("PARSER FAIL", header)
    exit(1)
}
let server = TelegramCastLocalServer(source: FileSource(CommandLine.arguments[1]))!
server.start(host: "127.0.0.1") { result in
    if case let .success(url) = result {
        print("URL", url.absoluteString)
        fflush(stdout)
    } else {
        print("START FAILED")
        exit(1)
    }
}
dispatchMain()
EOF

if ! swiftc -O -swift-version 5 "$ROOT/submodules/TelegramCast/Sources/TelegramCastLocalServer.swift" main.swift -o server 2> compile.log; then
    cat compile.log
    exit 1
fi

head -c 7340033 /dev/urandom > blob.bin
EXPECTED="$(shasum -a 256 blob.bin | cut -d' ' -f1)"
./server blob.bin > server.log 2>&1 &
SERVER=$!
for _ in $(seq 1 50); do
    grep -q URL server.log && break
    python3 -c 'import time; time.sleep(0.1)'
done
URL="$(awk '/URL/{print $2}' server.log)"
if [ -z "$URL" ]; then
    cat server.log
    exit 1
fi
BASE="${URL%/cast/*}"
PORT="${BASE##*:}"
TOKEN_PATH="${URL#"$BASE"}"
code() { curl -s --noproxy '*' -o /dev/null -w '%{http_code}' "$@"; }
bytes() { python3 -I -c "import hashlib,sys;f=open('blob.bin','rb');f.seek($1);print(hashlib.sha256(f.read($2)).hexdigest())"; }

check "full GET is byte-identical" "$(curl -s "$URL" | shasum -a 256 | cut -d' ' -f1)" "$EXPECTED"
check "HEAD length" "$(curl -sI "$URL" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}')" "7340033"
check "HEAD advertises ranges" "$(curl -sI "$URL" | tr -d '\r' | awk 'tolower($1)=="accept-ranges:"{print $2}')" "bytes"
check "range status" "$(code -r 1000-1999 "$URL")" "206"
check "range bytes" "$(curl -s -r 1000-1999 "$URL" | shasum -a 256 | cut -d' ' -f1)" "$(bytes 1000 1000)"
check "Content-Range" "$(curl -s -D- -o /dev/null -r 7340000- "$URL" | tr -d '\r' | awk 'tolower($1)=="content-range:"{print $2,$3}')" "bytes 7340000-7340032/7340033"
check "suffix range" "$(curl -s -r -100 "$URL" | wc -c | tr -d ' ')" "100"
check "unsatisfiable range" "$(code -r 9999999- "$URL")" "416"
check "POST refused" "$(code -X POST "$URL")" "405"
check "wrong token" "$(code "$BASE/cast/deadbeef/video")" "404"
check "root" "$(code "$BASE/")" "404"
check "path traversal" "$(code --path-as-is "$BASE/cast/../../etc/passwd")" "404"

PIDS=""
for i in 1 2 3 4 5 6; do
    curl -s -r $((i * 100000))-$((i * 700000)) "$URL" -o "part$i" &
    PIDS="$PIDS $!"
done
wait $PIDS
for i in 1 2 3 4 5 6; do
    check "concurrent range $i" "$(shasum -a 256 "part$i" | cut -d' ' -f1)" "$(bytes $((i * 100000)) $((i * 600000 + 1)))"
done

check "oversized header" "$(python3 -I - "$PORT" <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
s.sendall(b"GET /" + b"a" * 20000)
s.settimeout(3)
print(s.recv(64).split(b" ")[1].decode())
PY
)" "431"

LAN_ADDRESS="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
if [ -n "$LAN_ADDRESS" ]; then
    check "a second client address is locked out" "$(code -r 0-9 "http://$LAN_ADDRESS:$PORT$TOKEN_PATH")" "403"
else
    echo "SKIP second client: no LAN address on this machine"
fi

exit $FAILED
