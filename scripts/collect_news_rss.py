# -*- coding: utf-8 -*-
"""Google News RSS 기반 1차 수집기 + 네이버 뉴스 API 보강 (daily-news-picker).

검증 이력: 2026-07-17 실측 (references/search-recipes.md 참조)
- Google News RSS가 기존 검색어 세트(Q1~Q5) 전체에서 작동, 기존 매체 로스터 커버 확인
- batchexecute 원문 URL 복원 107/107 성공
- 네이버 뉴스 API 인증·조회 작동 확인 — 정밀도가 낮아(형태소 분리 매칭) 주 엔진이 아닌
  100건 상한 도달·수집 실패 쿼리의 보강 엔진으로만 사용. originallink가 원문 URL이라 복원 불필요.

역할: 점검 창 내 후보 기사를 결정론적으로 수집해 JSON으로 저장한다.
선별·랭킹·요약은 기존 스킬 프롬프트(에이전트)가 수행한다.

사용:
    python collect_news_rss.py                       # 오늘 기준 창 (직전 업무일 05:00 ~ 오늘 05:00 KST)
    python collect_news_rss.py --date 2026-07-17     # 보고일 지정
    python collect_news_rss.py --start "2026-07-16 05:00" --end "2026-07-17 05:00"
    python collect_news_rss.py --out-dir <폴더>       # 기본: 현재 폴더
    python collect_news_rss.py --no-resolve          # 원문 URL 복원 생략(빠른 확인용)
    python collect_news_rss.py --self-test           # 순수 함수 자체 테스트
"""
import argparse
import json
import re
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime

sys.stdout.reconfigure(encoding="utf-8")

KST = timezone(timedelta(hours=9))
HEADERS = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}

# 검색어 세트 — references/search-recipes.md 의 Q1~Q5와 동기 유지할 것.
# 직속기관 목록 정본: references/institution-scope.md
QUERIES = [
    ("Q1", "인천교육청"),
    ("Q2", "인천교육지원청"),
    ("Q3", "인천 학생교육원"),
    ("Q4", "인천교육감"),
    ("Q5", "인천 AI융합교육원"),
    ("Q5", "인천 교육연수원"),
    ("Q5", "인천 학생교육문화회관"),
    ("Q5", "인천 평생학습관"),
    ("Q5", "인천 유아교육진흥원"),
    ("Q5", "인천 동아시아국제교육원"),
    ("Q5", "인천 난정평화교육원"),
    ("Q5", "인천 교직원수련원"),
    ("Q5", "인천 학교지원단"),
    ("Q5", "인천교육청 중앙도서관"),
    ("Q5", "인천교육청 주안도서관"),
    ("Q5", "인천교육청 부평도서관"),
    ("Q5", "인천교육청 연수도서관"),
    ("Q5", "인천교육청 계양도서관"),
    ("Q5", "인천교육청 화도진도서관"),
    ("Q5", "인천교육청 서구도서관"),
    ("Q5", "인천교육청 신트리도서관"),
]

# 배제 도메인 — 2026-07-17 실측에서 관찰된 비대상·재게재 소스
EXCLUDED_DOMAINS = {
    "korean.people.com.cn",  # 인민넷
    "www.vietnam.vn",
    "voi.id",
    "www.msn.com",
    "news.nate.com",
    "m.news.nate.com",
    "v.daum.net",
    "n.news.naver.com",
    "ppss.kr",
    "www.ppss.kr",
}

TRACKING_PARAMS = {"utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "ref", "source", "fbclid",
                   "wlog_tag3", "outurl", "influxdiv"}  # 뒤 3개: 네이버 유입 추적 (실측 2026-07-17)


# ---------- 순수 함수 ----------

def title_key(title: str) -> str:
    """엔진 간 중복 판별용 제목 키 (공백·특수문자 제거). 같은 기사가 m./www. 등 다른 URL로 잡히는 경우 대비."""
    return re.sub(r"[^0-9A-Za-z가-힣]", "", title).lower()


def strip_html_tags(text: str) -> str:
    """네이버 API 제목의 <b> 태그·HTML 엔티티 제거."""
    import html
    return html.unescape(re.sub(r"</?b>", "", text))


def strip_source_suffix(title: str, source_name: str) -> str:
    """RSS 제목 끝의 ' - 언론사명' 꼬리를 제거한다."""
    suffix = f" - {source_name}"
    if source_name and title.endswith(suffix):
        return title[: -len(suffix)].strip()
    return title.strip()


def clean_url(url: str) -> str:
    """추적 파라미터만 제거하고 나머지는 보존한다."""
    parts = urllib.parse.urlsplit(url)
    if not parts.query:
        return url
    kept = [(k, v) for k, v in urllib.parse.parse_qsl(parts.query, keep_blank_values=True)
            if k.lower() not in TRACKING_PARAMS]
    query = urllib.parse.urlencode(kept)
    return urllib.parse.urlunsplit((parts.scheme, parts.netloc, parts.path, query, parts.fragment))


def previous_business_day(date):
    """토·일만 건너뛴 직전 업무일. 공휴일 처리는 러너(PowerShell) 쪽 창 인자를 신뢰한다."""
    d = date - timedelta(days=1)
    while d.weekday() >= 5:
        d -= timedelta(days=1)
    return d


def in_window(published_kst: datetime, start: datetime, end: datetime) -> bool:
    return start <= published_kst < end


def gnews_range_operator(start: datetime, end: datetime) -> str:
    """점검 창을 정밀 타격하는 after:/before: 연산자.

    실측(2026-07-17): Google News는 날짜를 미국 태평양시(PT) 기준으로 해석한다.
    when:Nd 방식은 100건 상한이 최신 기사로 채워져 과거 창 기사가 밀려나는 문제가 있어
    (백필 실측: when 방식 창 내 6건 vs 정밀 범위 31건) 창에 맞춘 날짜 범위를 쓴다.
    경계 오차(PDT/PST ±1h)는 이후 pubDate 정밀 필터가 흡수한다.
    """
    pt = timezone(timedelta(hours=-7))
    after = start.astimezone(pt).date()
    before = end.astimezone(pt).date() + timedelta(days=1)
    return f"after:{after:%Y-%m-%d} before:{before:%Y-%m-%d}"


# ---------- 네이버 뉴스 API (보강 엔진) ----------

def naver_keys():
    """환경변수 또는 사용자 레지스트리에서 네이버 키를 읽는다. 값은 절대 출력하지 않는다."""
    import os
    cid = os.environ.get("NAVER_CLIENT_ID")
    csec = os.environ.get("NAVER_CLIENT_SECRET")
    if not (cid and csec):
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
                if not cid:
                    cid, _ = winreg.QueryValueEx(key, "NAVER_CLIENT_ID")
                if not csec:
                    csec, _ = winreg.QueryValueEx(key, "NAVER_CLIENT_SECRET")
        except OSError:
            return None, None
    return (cid.strip() if cid else None), (csec.strip() if csec else None)


def fetch_naver(query: str, client_id: str, client_secret: str, display: int = 100, start: int = 1):
    """네이버 뉴스 검색 API. originallink가 언론사 원문 URL, pubDate는 KST(+0900)."""
    q = urllib.parse.quote(query)
    url = f"https://openapi.naver.com/v1/search/news.json?query={q}&display={display}&sort=date&start={start}"
    req = urllib.request.Request(url)
    req.add_header("X-Naver-Client-Id", client_id)
    req.add_header("X-Naver-Client-Secret", client_secret)
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return data.get("items", [])


def fetch_naver_window(query: str, client_id: str, client_secret: str, window_start: datetime):
    """최신순 페이지네이션으로 창 시작 이전 기사가 나올 때까지 수집 (start 최대 1000)."""
    items = []
    start = 1
    while start <= 1000:
        page = fetch_naver(query, client_id, client_secret, display=100, start=start)
        if not page:
            break
        items.extend(page)
        try:
            oldest = parsedate_to_datetime(page[-1]["pubDate"]).astimezone(KST)
            if oldest < window_start:
                break
        except Exception:
            break
        start += 100
        time.sleep(0.2)
    return items


# ---------- 수집 ----------

def fetch_rss(query: str, when: str):
    q = urllib.parse.quote(f"{query} {when}")
    url = f"https://news.google.com/rss/search?q={q}&hl=ko&gl=KR&ceid=KR:ko"
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=30) as resp:
        root = ET.fromstring(resp.read())
    items = []
    for item in root.iter("item"):
        source = item.find("source")
        items.append({
            "title": item.findtext("title") or "",
            "link": item.findtext("link") or "",
            "pubdate": item.findtext("pubDate") or "",
            "source_name": source.text if source is not None else "",
            "source_url": source.get("url") if source is not None else "",
        })
    return items


def resolve_original_url(google_link: str):
    """news.google.com 리다이렉트 링크 → 언론사 원문 URL (실측 2026-07-17, 6/6 성공)."""
    m = re.search(r"/articles/([^?]+)", google_link)
    if not m:
        return None
    article_id = m.group(1)
    req = urllib.request.Request(google_link, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=20) as resp:
        body = resp.read().decode("utf-8", errors="replace")
    sig = re.search(r'data-n-a-sg="([^"]+)"', body)
    ts = re.search(r'data-n-a-ts="([^"]+)"', body)
    if not (sig and ts):
        return None
    payload_inner = json.dumps([
        "garturlreq",
        [["X", "X", ["X", "X"], None, None, 1, 1, "KR:ko", None, 1, None, None, None, None, None, 0, 1],
         "X", "X", 1, [1, 1, 1], 1, 1, None, 0, 0, None, 0],
        article_id, ts.group(1), sig.group(1),
    ])
    f_req = json.dumps([[["Fbv4je", payload_inner, None, "generic"]]])
    data = urllib.parse.urlencode({"f.req": f_req}).encode("utf-8")
    req = urllib.request.Request(
        "https://news.google.com/_/DotsSplashUi/data/batchexecute",
        data=data,
        headers={**HEADERS, "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8"},
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        text = resp.read().decode("utf-8", errors="replace")
    for line in text.splitlines():
        if '"Fbv4je"' not in line:
            continue
        try:
            outer = json.loads(line)
        except json.JSONDecodeError:
            continue
        for entry in outer:
            if isinstance(entry, list) and len(entry) > 2 and entry[0] == "wrb.fr":
                inner = json.loads(entry[2])
                found = []

                def walk(node):
                    if isinstance(node, str) and node.startswith("http") and "google.com" not in node:
                        found.append(node)
                    elif isinstance(node, list):
                        for x in node:
                            walk(x)

                walk(inner)
                if found:
                    return found[0]
    return None


def collect(window_start: datetime, window_end: datetime, resolve: bool = True):
    range_op = gnews_range_operator(window_start, window_end)
    seen_ids = {}
    failures = []

    for label, query in QUERIES:
        try:
            items = fetch_rss(query, range_op)
        except Exception as e:
            failures.append({"query": query, "label": label, "error": str(e)})
            print(f"[수집 실패] {label} '{query}': {e}", file=sys.stderr)
            continue
        capped = len(items) >= 100
        kept = 0
        for it in items:
            try:
                pub = parsedate_to_datetime(it["pubdate"]).astimezone(KST)
            except Exception:
                continue
            if not in_window(pub, window_start, window_end):
                continue
            source_domain = urllib.parse.urlsplit(it["source_url"]).netloc if it["source_url"] else ""
            if source_domain in EXCLUDED_DOMAINS:
                continue
            gid_m = re.search(r"/articles/([^?]+)", it["link"])
            gid = gid_m.group(1) if gid_m else it["link"]
            if gid in seen_ids:
                seen_ids[gid]["queries"].append(f"{label}:{query}")
                continue
            seen_ids[gid] = {
                "title": strip_source_suffix(it["title"], it["source_name"]),
                "publisher": it["source_name"],
                "publisher_domain": source_domain,
                "google_url": it["link"],
                "original_url": None,
                "url_status": "미복원",
                "published_at_kst": pub.strftime("%Y-%m-%d %H:%M"),
                "queries": [f"{label}:{query}"],
                "engine": "google-news-rss",
            }
            kept += 1
        cap_note = " (⚠️ 100건 상한 도달 — 창 초반 기사 누락 가능)" if capped else ""
        print(f"[{label}] '{query}' → 창 내 신규 {kept}건{cap_note}")
        if capped:
            failures.append({"query": query, "label": label, "error": "100건 상한 도달"})

    articles = list(seen_ids.values())

    if resolve:
        print(f"\n원문 URL 복원 중... ({len(articles)}건)")
        for i, art in enumerate(articles, 1):
            for attempt in (1, 2):
                try:
                    url = resolve_original_url(art["google_url"])
                    if url:
                        art["original_url"] = clean_url(url)
                        art["url_status"] = "복원"
                    break
                except Exception:
                    if attempt == 2:
                        break
                    time.sleep(2)
            time.sleep(0.5)
            if i % 10 == 0:
                print(f"  {i}/{len(articles)}")
        resolved = sum(1 for a in articles if a["url_status"] == "복원")
        print(f"복원 완료: {resolved}/{len(articles)}")

    # 상한 도달·수집 실패 쿼리는 네이버 뉴스 API로 보강 (키 없으면 건너뜀)
    supplement_queries = [(f["label"], f["query"]) for f in failures]
    if supplement_queries:
        cid, csec = naver_keys()
        if cid and csec:
            known_urls = {a["original_url"] for a in articles if a.get("original_url")}
            known_titles = {title_key(a["title"]) for a in articles}
            added = 0
            for label, query in supplement_queries:
                try:
                    items = fetch_naver_window(query, cid, csec, window_start)
                except Exception as e:
                    print(f"[네이버 보강 실패] {label} '{query}': {e}", file=sys.stderr)
                    continue
                for it in items:
                    try:
                        pub = parsedate_to_datetime(it["pubDate"]).astimezone(KST)
                    except Exception:
                        continue
                    if not in_window(pub, window_start, window_end):
                        continue
                    original = clean_url(it.get("originallink") or it.get("link") or "")
                    if not original:
                        continue
                    domain = urllib.parse.urlsplit(original).netloc
                    if domain in EXCLUDED_DOMAINS:
                        continue
                    title = strip_html_tags(it.get("title", "")).strip()
                    if original in known_urls or title_key(title) in known_titles:
                        continue
                    known_urls.add(original)
                    known_titles.add(title_key(title))
                    articles.append({
                        "title": title,
                        "publisher": "",  # 네이버 API는 매체명 미제공 — 도메인으로 후속 판별
                        "publisher_domain": domain,
                        "google_url": None,
                        "original_url": original,
                        "url_status": "원문직접",
                        "published_at_kst": pub.strftime("%Y-%m-%d %H:%M"),
                        "queries": [f"{label}:{query}"],
                        "engine": "naver-api",
                    })
                    added += 1
            print(f"네이버 API 보강: 대상 쿼리 {len(supplement_queries)}개에서 신규 {added}건 추가")
        else:
            print("네이버 API 키 미설정 — 보강 생략 (환경변수 NAVER_CLIENT_ID/SECRET)")

    articles.sort(key=lambda a: a["published_at_kst"])
    return articles, failures


# ---------- 자체 테스트 ----------

def self_test():
    assert strip_source_suffix("제목 A - 기호일보", "기호일보") == "제목 A"
    assert strip_source_suffix("제목 - 없는매체", "기호일보") == "제목 - 없는매체"
    assert clean_url("https://a.kr/n?idxno=1&utm_source=x&ref=y") == "https://a.kr/n?idxno=1"
    assert clean_url("https://a.kr/n/123") == "https://a.kr/n/123"
    assert clean_url("https://a.kr/n?idxno=1&wlog_tag3=naver") == "https://a.kr/n?idxno=1"
    assert strip_html_tags("<b>인천</b>교육청 &quot;발표&quot;") == '인천교육청 "발표"'
    assert title_key("인천교육청, 발표!") == title_key("인천교육청 발표")
    # 2026-07-13은 월요일 → 직전 업무일은 금요일 7/10
    assert previous_business_day(datetime(2026, 7, 13)) == datetime(2026, 7, 10)
    assert previous_business_day(datetime(2026, 7, 17)) == datetime(2026, 7, 16)
    s = datetime(2026, 7, 16, 5, 0, tzinfo=KST)
    e = datetime(2026, 7, 17, 5, 0, tzinfo=KST)
    assert in_window(datetime(2026, 7, 16, 5, 0, tzinfo=KST), s, e)
    assert not in_window(datetime(2026, 7, 17, 5, 0, tzinfo=KST), s, e)
    # 7/16 05:00 KST = 7/15 13:00 PT → after:07-15 / 7/17 05:00 KST = 7/16 13:00 PT → before:07-17
    assert gnews_range_operator(s, e) == "after:2026-07-15 before:2026-07-17"
    print("self-test OK")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--date", help="보고일 YYYY-MM-DD (기본: 오늘)")
    parser.add_argument("--start", help="창 시작 'YYYY-MM-DD HH:MM' KST")
    parser.add_argument("--end", help="창 종료 'YYYY-MM-DD HH:MM' KST")
    parser.add_argument("--out-dir", default=".", help="저장 폴더")
    parser.add_argument("--no-resolve", action="store_true", help="원문 URL 복원 생략")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return

    if args.start and args.end:
        window_start = datetime.strptime(args.start, "%Y-%m-%d %H:%M").replace(tzinfo=KST)
        window_end = datetime.strptime(args.end, "%Y-%m-%d %H:%M").replace(tzinfo=KST)
    else:
        report_date = datetime.strptime(args.date, "%Y-%m-%d") if args.date else datetime.now(KST).replace(tzinfo=None)
        report_date = report_date.replace(hour=0, minute=0, second=0, microsecond=0)
        window_start = previous_business_day(report_date).replace(hour=5, tzinfo=KST)
        window_end = report_date.replace(hour=5, tzinfo=KST)

    print(f"점검 창: {window_start:%Y-%m-%d %H:%M} ~ {window_end:%Y-%m-%d %H:%M} KST\n")
    articles, failures = collect(window_start, window_end, resolve=not args.no_resolve)

    out = {
        "window_start": f"{window_start:%Y-%m-%d %H:%M}",
        "window_end": f"{window_end:%Y-%m-%d %H:%M}",
        "collected_at": f"{datetime.now(KST):%Y-%m-%d %H:%M}",
        "engine": "google-news-rss",
        "article_count": len(articles),
        "failures": failures,
        "articles": articles,
    }
    import os
    os.makedirs(args.out_dir, exist_ok=True)
    out_path = os.path.join(args.out_dir, "collected_articles.json")
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(f"\n저장: {out_path} ({len(articles)}건, 수집 실패 {len(failures)}건)")


if __name__ == "__main__":
    main()
