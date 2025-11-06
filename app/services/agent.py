import os
import json
import logging

from .tools import registry

# Set up logger
logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


# Default to gemini-2.0-flash (works with public API)
# For Vertex AI, may need to use gemini-1.5-pro if 2.0-flash not available
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-2.0-flash")


def _use_vertex_mode() -> bool:
    # Use Vertex AI when in GCP environment (uses Application Default Credentials)
    # No API key needed when running in GCP
    if os.getenv("USE_VERTEX") == "1":
        return True
    # Check if we're in a GCP environment (has GOOGLE_CLOUD_PROJECT or ADC available)
    if os.getenv("GOOGLE_CLOUD_PROJECT"):
        return True
    # Try to detect GCP environment via metadata server
    try:
        import requests
        response = requests.get(
            "http://metadata.google.internal/computeMetadata/v1/project/project-id",
            headers={"Metadata-Flavor": "Google"},
            timeout=1
        )
        if response.status_code == 200:
            return True
    except Exception:
        pass
    return False


def _vertex_build_tools():
    try:
        from vertexai.generative_models import Tool, FunctionDeclaration
    except Exception:
        return None

    decls = []
    for d in registry.tool_declarations():
        decls.append(
            FunctionDeclaration(
                name=d.get("name"),
                description=d.get("description", ""),
                parameters=d.get("parameters", {}),
            )
        )
    return [Tool(function_declarations=decls)]


def _google_genai_model():
    import google.generativeai as genai

    api_key = os.getenv("GEMINI_API_KEY")
    if not api_key:
        raise RuntimeError("Missing GEMINI_API_KEY. Set it in environment or use Vertex AI in GCP.")
    genai.configure(api_key=api_key)
    return genai.GenerativeModel(model_name=GEMINI_MODEL)


def _vertex_model():
    from vertexai import init as vertex_init
    from vertexai.generative_models import GenerativeModel

    project = os.getenv("GOOGLE_CLOUD_PROJECT")
    location = os.getenv("VERTEX_LOCATION", "us-central1")
    if not project:
        raise RuntimeError("Vertex mode requires GOOGLE_CLOUD_PROJECT env var")
    vertex_init(project=project, location=location)
    
    model_name = GEMINI_MODEL
    
    # Try the requested model first
    try:
        return GenerativeModel(model_name)
    except Exception as e:
        error_msg = str(e)
        # If model not found or permission denied, try fallback
        if "not found" in error_msg.lower() or "permission" in error_msg.lower():
            if model_name == "gemini-2.0-flash":
                # gemini-2.0-flash may not be available in Vertex AI yet
                # Try gemini-1.5-flash-exp or gemini-1.5-pro as fallback
                fallback_models = ["gemini-1.5-flash-exp", "gemini-1.5-flash", "gemini-1.5-pro"]
                for fallback in fallback_models:
                    try:
                        print(f"Warning: Model {model_name} not available in Vertex AI, trying {fallback}")
                        return GenerativeModel(fallback)
                    except Exception:
                        continue
                # If all fallbacks fail, raise original error
            raise RuntimeError(f"Model {model_name} not available in Vertex AI. Error: {error_msg}")
        raise


def _extract_function_calls(resp):
    calls = []
    try:
        for cand in resp.candidates or []:
            for part in (cand.content.parts or []):
                if getattr(part, "function_call", None):
                    calls.append(part.function_call)
    except Exception:
        pass
    return calls


async def run_agent(user_prompt: str):
    try:
        vertex_mode = _use_vertex_mode()
        model = _vertex_model() if vertex_mode else _google_genai_model()
        tools = _vertex_build_tools() if vertex_mode else [{"function_declarations": registry.tool_declarations()}]
    except Exception as e:
        return {"text": f"Error initializing model: {str(e)}", "tools": []}

    history = [{"role": "user", "parts": [{"text": user_prompt}]}]
    tool_trace = []

    for _ in range(6):
        if vertex_mode:
            resp = model.generate_content(contents=history, tools=tools)
        else:
            resp = model.generate_content({"contents": history, "tools": tools})
        calls = _extract_function_calls(resp)

        # No tool calls → return text if available
        try:
            text = resp.text
        except Exception:
            text = None

        if not calls:
            return {"text": text or "", "tools": tool_trace}

        # Execute tool calls
        for call in calls:
            name = call.name
            # Convert MapComposite to dict for JSON serialization
            if hasattr(call.args, 'to_dict'):
                args = call.args.to_dict()
            elif hasattr(call.args, '__dict__'):
                args = dict(call.args)
            else:
                args = dict(call.args) if call.args else {}
            logger.info(f"[TOOL_CALL] Tool: {name}, Args: {json.dumps(args, default=str)}")
            result = await registry.handle_tool(name, args)
            logger.info(f"[TOOL_RESULT] Tool: {name}, Result: {str(result)[:200]}")
            # Ensure result is JSON serializable
            if not isinstance(result, (str, int, float, bool, type(None), dict, list)):
                result = str(result)
            tool_trace.append({"name": name, "args": args, "result": result})

            history.append({
                "role": "tool",
                "parts": [{
                    "function_response": {
                        "name": name,
                        "response": {"name": name, "content": result},
                    }
                }],
            })

    return {"text": "Reached tool-call step limit.", "tools": tool_trace}


