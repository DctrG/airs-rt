import httpx


async def web_search(params: dict):
    query = (params or {}).get("query")
    region = (params or {}).get("region")
    if not query:
        return {"error": "Missing query"}

    url = "https://api.duckduckgo.com/"
    q = {"q": query, "format": "json"}
    if region:
        q["kl"] = region

    try:
        async with httpx.AsyncClient(timeout=15) as client:
            res = await client.get(url, params=q, headers={"user-agent": "gemini-agent/1.0"})
            res.raise_for_status()
            data = res.json()

        results = []
        if data.get("AbstractText"):
            results.append({
                "title": data.get("Heading") or "Abstract",
                "snippet": data.get("AbstractText"),
                "url": data.get("AbstractURL"),
            })
        for item in data.get("RelatedTopics", []) or []:
            if item and item.get("Text") and item.get("FirstURL"):
                results.append({"title": item["Text"][:120], "snippet": item["Text"], "url": item["FirstURL"]})
            elif item and isinstance(item.get("Topics"), list):
                for sub in item["Topics"]:
                    if sub and sub.get("Text") and sub.get("FirstURL"):
                        results.append({"title": sub["Text"][:120], "snippet": sub["Text"], "url": sub["FirstURL"]})

        return {"query": query, "results": results[:8]}
    except Exception as e:
        return {"error": str(e)}


