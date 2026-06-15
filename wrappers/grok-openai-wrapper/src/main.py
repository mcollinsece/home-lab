"""
grok-openai-wrapper: Expose Grok Build CLI as an OpenAI-compatible endpoint

Same pattern as claude-code-openai-wrapper:
- Grok Build CLI authenticated via OAuth (auth.json)
- Spawn `grok --headless` as subprocess
- Wrap in FastAPI for OpenAI compatibility
- Expose via LiteLLM to director

No API keys, no anthropic-proxy - just pure Grok CLI + OAuth subscription.
"""

from fastapi import FastAPI, HTTPException, Header
from pydantic import BaseModel
from typing import Optional, List
import os
import time
import logging
import subprocess
import json
import tempfile

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Grok OpenAI Wrapper")

# Configuration
WRAPPER_API_KEY = os.getenv("API_KEY", "grok-internal-revproxy-key-2026")
GROK_BIN = os.getenv("GROK_BIN", "/root/.grok/bin/grok")
GROK_CWD = os.getenv("GROK_CWD", "/tmp/grok-workspace")

# OpenAI request models
class ChatMessage(BaseModel):
    role: str
    content: str

class ChatCompletionRequest(BaseModel):
    model: str
    messages: List[ChatMessage]
    temperature: Optional[float] = 0.7
    max_tokens: Optional[int] = None
    stream: Optional[bool] = False

def verify_api_key(authorization: Optional[str] = Header(None)) -> bool:
    if not authorization:
        return False
    token = authorization.replace("Bearer ", "").strip()
    return token == WRAPPER_API_KEY

@app.get("/")
async def root():
    grok_auth_exists = os.path.exists("/root/.grok/auth.json")
    grok_bin_exists = os.path.exists(GROK_BIN)
    return {
        "status": "ok",
        "service": "grok-openai-wrapper",
        "grok_auth": grok_auth_exists,
        "grok_bin": grok_bin_exists
    }

@app.get("/health")
async def health():
    grok_ready = os.path.exists("/root/.grok/auth.json") and os.path.exists(GROK_BIN)
    return {
        "status": "healthy" if grok_ready else "unhealthy",
        "grok_authenticated": os.path.exists("/root/.grok/auth.json"),
        "grok_binary": os.path.exists(GROK_BIN)
    }

@app.get("/v1/models")
async def list_models(authorization: Optional[str] = Header(None)):
    if not verify_api_key(authorization):
        raise HTTPException(status_code=401, detail="Invalid API key")

    return {
        "object": "list",
        "data": [
            {"id": "grok-wrapper-local", "object": "model", "created": int(time.time()), "owned_by": "xai"},
            {"id": "grok-beta", "object": "model", "created": int(time.time()), "owned_by": "xai"},
        ]
    }

@app.post("/v1/chat/completions")
async def chat_completions(
    request: ChatCompletionRequest,
    authorization: Optional[str] = Header(None)
):
    """
    Process OpenAI-format requests by spawning grok CLI

    Similar to claude-code-wrapper: spawn the authenticated CLI binary,
    pass the prompt, return output in OpenAI format.
    """
    if not verify_api_key(authorization):
        raise HTTPException(status_code=401, detail="Invalid API key")

    if not os.path.exists("/root/.grok/auth.json"):
        raise HTTPException(status_code=401, detail="Grok not authenticated - run grok login")

    if not os.path.exists(GROK_BIN):
        raise HTTPException(status_code=500, detail=f"Grok binary not found at {GROK_BIN}")

    # Build prompt from messages
    prompt_parts = []
    for msg in request.messages:
        if msg.role == "system":
            prompt_parts.append(f"System: {msg.content}")
        elif msg.role == "user":
            prompt_parts.append(f"User: {msg.content}")
        elif msg.role == "assistant":
            prompt_parts.append(f"Assistant: {msg.content}")

    prompt = "\n\n".join(prompt_parts)

    # Ensure workspace exists
    os.makedirs(GROK_CWD, exist_ok=True)

    try:
        # Spawn grok CLI in single-shot mode
        # -p, --single: non-interactive mode
        # --output-format json: structured output
        # --cwd: working directory for file operations
        # --no-alt-screen: disable TUI
        result = subprocess.run(
            [GROK_BIN, "--single", prompt, "--output-format", "json", "--cwd", GROK_CWD, "--no-alt-screen"],
            capture_output=True,
            text=True,
            timeout=300,  # 5 minute timeout
            env=os.environ.copy()
        )

        if result.returncode != 0:
            logger.error(f"Grok CLI failed: {result.stderr}")
            raise HTTPException(status_code=500, detail=f"Grok CLI error: {result.stderr}")

        # Parse JSON output
        try:
            grok_output = json.loads(result.stdout)
            # Grok's JSON format may vary - extract the response text
            # This is a best-guess based on typical CLI output
            response_text = grok_output.get("response", result.stdout)
        except json.JSONDecodeError:
            # Fall back to plain text if JSON parsing fails
            response_text = result.stdout

        # Return in OpenAI format
        return {
            "id": f"chatcmpl-grok-{int(time.time())}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": request.model,
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": response_text
                },
                "finish_reason": "stop"
            }],
            "usage": {
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "total_tokens": 0
            }
        }

    except subprocess.TimeoutExpired:
        logger.error("Grok CLI timeout")
        raise HTTPException(status_code=504, detail="Grok CLI timeout")
    except Exception as e:
        logger.error(f"Error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    import uvicorn
    port = int(os.getenv("PORT", "8001"))
    uvicorn.run(app, host="0.0.0.0", port=port)
