from .web_search import web_search
from .fetch_url import fetch_url
from .calculator import calculator


def tool_declarations():
    return [
        {
            "name": "web_search",
            "description": "Search the web using DuckDuckGo Instant Answer API.",
            "parameters": {
                "type": "OBJECT",
                "properties": {
                    "query": {"type": "STRING", "description": "Search query"},
                    "region": {"type": "STRING", "description": "Region code", "nullable": True},
                },
                "required": ["query"],
            },
        },
        {
            "name": "fetch_url",
            "description": "Fetch a URL and extract readable text.",
            "parameters": {
                "type": "OBJECT",
                "properties": {"url": {"type": "STRING", "description": "URL to fetch"}},
                "required": ["url"],
            },
        },
        {
            "name": "calculator",
            "description": "Safely evaluate a mathematical expression.",
            "parameters": {
                "type": "OBJECT",
                "properties": {"expression": {"type": "STRING", "description": "Math expression"}},
                "required": ["expression"],
            },
        },
    ]


async def handle_tool(name: str, args: dict):
    if name == "web_search":
        return await web_search(args)
    if name == "fetch_url":
        return await fetch_url(args)
    if name == "calculator":
        return await calculator(args)
    return {"error": f"Unknown tool: {name}"}


