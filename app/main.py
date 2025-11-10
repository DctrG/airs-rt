import os
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from dotenv import load_dotenv

from .routes import api

load_dotenv()

app = FastAPI(title="AI Agent App", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(api.router, prefix="/api")

base_dir = os.path.dirname(__file__)
static_dir = os.path.join(base_dir, "static")
templates_dir = os.path.join(base_dir, "templates")

# Only mount static files if directory exists
if os.path.exists(static_dir):
    app.mount("/static", StaticFiles(directory=static_dir), name="static")


@app.get("/health")
async def health():
    """Health check endpoint for Cloud Run"""
    return {"status": "ok"}


@app.get("/", response_class=HTMLResponse)
async def index(_: Request):
    index_path = os.path.join(templates_dir, "index.html")
    if os.path.exists(index_path):
        with open(index_path, "r", encoding="utf-8") as f:
            return HTMLResponse(content=f.read(), status_code=200)
    else:
        return HTMLResponse(content="<h1>Gemini Agent API</h1><p>API is running. Use /api/chat endpoint.</p>", status_code=200)


