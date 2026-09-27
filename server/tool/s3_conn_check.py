# 缤纷云 S3 SigV4 连通性验证（纯标准库）。凭据从环境读取（先 source .secrets/externals.local.env
# 或用 --env 传入）。尝试多个 region，找出该服务接受的签名域。
import datetime
import hashlib
import hmac
import os
import sys
import urllib.error
import urllib.request
from xml.etree import ElementTree

AK = os.environ.get("BITIFUL_S3_AK", "")
SK = os.environ.get("BITIFUL_S3_SK", "")
ENDPOINT = os.environ.get("BITIFUL_S3_ENDPOINT", "https://s3.bitiful.net")
BUCKET = os.environ.get("BITIFUL_S3_BUCKET", "qoderwork")


def sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def request(method: str, path: str, region: str, body: bytes = b"") -> tuple[int, str]:
    host = ENDPOINT.split("//", 1)[1]
    url = ENDPOINT + path
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(body).hexdigest()

    headers = {
        "host": host,
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amz_date,
    }
    signed = ";".join(sorted(headers))
    canon_headers = "".join(f"{k}:{v}\n" for k, v in sorted(headers.items()))
    canon_request = "\n".join([method, path, "", canon_headers, signed, payload_hash])
    scope = f"{date_stamp}/{region}/s3/aws4_request"
    string_to_sign = "\n".join(
        ["AWS4-HMAC-SHA256", amz_date, scope,
         hashlib.sha256(canon_request.encode()).hexdigest()]
    )
    k = sign(("AWS4" + SK).encode(), date_stamp)
    k = sign(k, region)
    k = sign(k, "s3")
    k = sign(k, "aws4_request")
    signature = hmac.new(k, string_to_sign.encode(), hashlib.sha256).hexdigest()
    headers["Authorization"] = (
        f"AWS4-HMAC-SHA256 Credential={AK}/{scope}, "
        f"SignedHeaders={signed}, Signature={signature}"
    )
    req = urllib.request.Request(url, data=body if body or method in ("PUT", "POST") else None,
                                 method=method)
    for h, v in headers.items():
        req.add_header(h, v)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except Exception as e:  # noqa: BLE001
        return -1, str(e)


def roundtrip(region: str) -> bool:
    """对象级 PUT/GET/HEAD/DELETE 往返（ListBuckets 被拒不代表对象操作被拒）。"""
    key = f"/{BUCKET}/zaoji/_conn_check.txt"
    data = b"zaoji-conn-check"
    c1, b1 = request("PUT", key, region, data)
    c2, b2 = request("GET", key, region)
    c3, _ = request("HEAD", key, region)
    c4, _ = request("DELETE", key, region)
    ok = c1 in (200, 201) and c2 == 200 and b2.startswith(b"zaoji") and c4 in (204, 200)
    print(f"[{region:16}] PUT={c1} GET={c2} HEAD={c3} DELETE={c4} -> {'往返通过' if ok else '未通过'}")
    if c1 not in (200, 201):
        print("   PUT 响应体:", b1[:200].replace("\n", " "))
    return ok


def main() -> None:
    if not AK or not SK:
        sys.exit("缺少 BITIFUL_S3_AK/SK 环境变量（先 source .secrets/externals.local.env）")
    for region in ["auto", "us-east-1"]:
        code, body = request("GET", "/", region)
        print(f"[{region:16}] ListBuckets -> {code} {body[:100].replace(chr(10), ' ')}")
        if roundtrip(region):
            return
    print("ALL REGIONS FAILED -- check docs for real region/signing requirements")


main()
