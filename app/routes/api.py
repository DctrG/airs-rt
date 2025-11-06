import logging
from datetime import datetime
from fastapi import APIRouter, Request, HTTPException, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from ..services.agent import run_agent

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


router = APIRouter()


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
    
    logger.info(f"[API_REQUEST] {timestamp} | IP: {client_ip} | POST /api/chat | Prompt: {req.prompt[:100]} | Headers: {headers}")
    
    try:
        result = await run_agent(req.prompt)
        
        # Check if result indicates an error
        if result.get("error"):
            error_msg = result.get("error", "Unknown error")
            logger.error(f"[API_ERROR] {timestamp} | IP: {client_ip} | Status: 500 | Error: {error_msg} | Headers: {headers}")
            return JSONResponse(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                content={
                    "error": error_msg,
                    "text": result.get("text", f"Error: {error_msg}"),
                    "tools": result.get("tools", [])
                }
            )
        
        # Log successful response
        response_text = result.get("text", "")[:200]  # First 200 chars
        tools_used = len(result.get("tools", []))
        logger.info(f"[API_RESPONSE] {timestamp} | IP: {client_ip} | Status: 200 OK | Tools: {tools_used} | Response: {response_text}")
        
        # Return 200 OK - standard for agent/chat APIs (not creating a resource, just processing and returning result)
        return JSONResponse(
            status_code=status.HTTP_200_OK,
            content=result
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
                "text": f"Error: {error_msg}",
                "tools": []
            }
        )


