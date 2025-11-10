import logging
from datetime import datetime
from fastapi import APIRouter, Request, HTTPException, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from ..services.agent import run_agent, GEMINI_MODEL

# Set up logger
logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# Create console handler if not exists
if not logger.handlers:
    handler = logging.StreamHandler()
    handler.setLevel(logging.INFO)
    formatter = logging.Formatter(
        '%(asctime)s - %(name)s - %(levelname)s - %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S'
    )
    handler.setFormatter(formatter)
    logger.addHandler(handler)


class ChatRequest(BaseModel):
    prompt: str
    model: str = None  # Optional model override


router = APIRouter()


@router.get("/models")
async def get_models(request: Request):
    """Get list of available Gemini models from Vertex AI"""
    try:
        from vertexai import init as vertex_init
        from vertexai.generative_models import GenerativeModel
        import os
        
        project = os.getenv("GOOGLE_CLOUD_PROJECT")
        location = os.getenv("VERTEX_LOCATION", "us-central1")
        
        if not project:
            # Try to detect from metadata server
            try:
                import requests
                response = requests.get(
                    "http://metadata.google.internal/computeMetadata/v1/project/project-id",
                    headers={"Metadata-Flavor": "Google"},
                    timeout=1
                )
                if response.status_code == 200:
                    project = response.text
            except Exception:
                pass
        
        if not project:
            return JSONResponse(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                content={"error": "Could not determine GCP project"}
            )
        
        vertex_init(project=project, location=location)
        
        # List of known Gemini models to check (most recent first)
        known_models = [
            "gemini-2.0-flash",
            "gemini-1.5-pro",
            "gemini-1.5-flash",
            "gemini-1.5-flash-exp",
            "gemini-pro",
        ]
        
        available_models = []
        for model_name in known_models:
            try:
                # Try to initialize the model to check if it's available
                model = GenerativeModel(model_name)
                # If no error, model is available
                available_models.append(model_name)
                if len(available_models) >= 3:  # Get top 3
                    break
            except Exception:
                # Model not available, skip
                continue
        
        if not available_models:
            # Fallback to default if none found
            available_models = [GEMINI_MODEL]
        
        return JSONResponse(
            status_code=status.HTTP_200_OK,
            content={"models": available_models}
        )
    except Exception as e:
        logger.error(f"Error fetching models: {str(e)}")
        # Return default models as fallback
        return JSONResponse(
            status_code=status.HTTP_200_OK,
            content={"models": ["gemini-2.0-flash", "gemini-1.5-pro", "gemini-1.5-flash"]}
        )


@router.post("/chat")
async def chat(req: ChatRequest, request: Request):
    timestamp = datetime.now().isoformat()
    client_ip = request.client.host if request.client else "unknown"
    
    # Extract relevant headers
    headers = {
        "user-agent": request.headers.get("user-agent", "unknown"),
        "content-type": request.headers.get("content-type", "unknown"),
        "accept": request.headers.get("accept", "unknown"),
        "authorization": "***" if request.headers.get("authorization") else "none",
        "x-forwarded-for": request.headers.get("x-forwarded-for", "none"),
        "x-real-ip": request.headers.get("x-real-ip", "none"),
    }
    
    # Validate request
    if not req.prompt or not req.prompt.strip():
        logger.warning(f"[API_ERROR] {timestamp} | IP: {client_ip} | Status: 400 | Error: Empty prompt | Headers: {headers}")
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Prompt cannot be empty"
        )
    
    model_used = req.model or "default"
    logger.info(f"[API_REQUEST] {timestamp} | IP: {client_ip} | POST /api/chat | Prompt: {req.prompt[:100]} | Model: {model_used} | Headers: {headers}")
    
    try:
        result = await run_agent(req.prompt, model=req.model)
        
        # Check if result indicates an error
        if result.get("error"):
            error_msg = result.get("error", "Unknown error")
            logger.error(f"[API_ERROR] {timestamp} | IP: {client_ip} | Status: 500 | Error: {error_msg} | Headers: {headers}")
            return JSONResponse(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                content={
                    "error": error_msg,
                    "text": result.get("text", f"Error: {error_msg}")
                }
            )
        
        # Log successful response
        response_text = result.get("text", "")[:200]  # First 200 chars
        tools_used = len(result.get("tools", []))
        logger.info(f"[API_RESPONSE] {timestamp} | IP: {client_ip} | Status: 200 OK | Tools: {tools_used} | Response: {response_text}")
        
        # Return only the text - tools are internal implementation details (still logged)
        return JSONResponse(
            status_code=status.HTTP_200_OK,
            content={
                "text": result.get("text", "")
            }
        )
    except HTTPException:
        # Re-raise HTTP exceptions (like 400 Bad Request)
        raise
    except Exception as e:
        import traceback
        error_msg = str(e)
        logger.error(f"[API_ERROR] {timestamp} | IP: {client_ip} | Status: 500 | Error: {error_msg} | Headers: {headers}")
        logger.error(f"[API_ERROR] {timestamp} | IP: {client_ip} | Traceback: {traceback.format_exc()}")
        return JSONResponse(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            content={
                "error": error_msg,
                "text": f"Error: {error_msg}"
            }
        )


