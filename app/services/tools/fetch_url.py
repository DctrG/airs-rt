import re
import httpx
from bs4 import BeautifulSoup


def extract_text(html: str) -> str:
    soup = BeautifulSoup(html, "html.parser")
    for tag in soup(["script", "style", "noscript"]):
        tag.decompose()
    text = soup.get_text(" ")
    text = re.sub(r"\s+", " ", text).strip()
    return text


async def fetch_url(params: dict):
    url = (params or {}).get("url")
    if not url:
        return {"error": "Missing url"}
    try:
        async with httpx.AsyncClient(timeout=20, follow_redirects=True) as client:
            res = await client.get(url, headers={"user-agent": "gemini-agent/1.0"})
            res.raise_for_status()
            content_type = res.headers.get("content-type", "")
            if "text" not in content_type and "html" not in content_type:
                return {"error": f"Unsupported content-type: {content_type}"}
            text = extract_text(res.text)
            return {"url": url, "contentType": content_type, "text": text[:8000]}
    except Exception as e:
        return {"error": str(e)}


