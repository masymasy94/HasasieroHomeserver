import os
import re
import json
import time
import asyncio
import logging
import subprocess
import httpx
from telegram import Update
from telegram.ext import (
    Application,
    CommandHandler,
    MessageHandler,
    filters,
    ContextTypes,
)
from telegram.constants import ChatAction

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger(__name__)

# --- Config ---
TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://ollama:11434")
DEFAULT_MODEL = os.environ.get("DEFAULT_MODEL", "qwen2.5:3b")
ALLOWED_IDS: set[int] = set()
raw = os.environ.get("ALLOWED_USER_IDS", "")
if raw.strip():
    ALLOWED_IDS = {int(uid.strip()) for uid in raw.split(",") if uid.strip()}

# Per-chat state
chats: dict[int, dict] = {}

EDIT_INTERVAL = 1.5
MAX_TOOL_ROUNDS = 5
COMMAND_TIMEOUT = 15  # seconds

# Regex to find <cmd>...</cmd> tags in model output
CMD_PATTERN = re.compile(r"<cmd>(.*?)</cmd>", re.DOTALL)

SYSTEM_PROMPT = """You are a helpful homeserver assistant with shell access to the server.
You run inside a Docker container and can execute commands to get real data.

IMPORTANT: When you need to check something on the server, you MUST write the command inside <cmd> tags. Examples:
- To check container memory: <cmd>docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"</cmd>
- To check disk: <cmd>df -h</cmd>
- To check RAM: <cmd>free -h</cmd>
- To see containers: <cmd>docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"</cmd>
- To see logs: <cmd>docker logs --tail 20 containername</cmd>

RULES:
- ALWAYS use <cmd> tags to run commands. Never just suggest commands — run them yourself.
- ALWAYS use --no-stream with docker stats (otherwise it hangs).
- After getting the command output, summarize it clearly for the user.
- Use the same language as the user (if they write in Italian, reply in Italian).
- Be concise and practical. Give real data, not disclaimers.
- You can run multiple commands if needed, each in its own <cmd> tag.
- The host /proc is at /host/proc (e.g. cat /host/proc/meminfo for host memory details).
- Do NOT use interactive commands (top without -bn1, htop, watch, etc.)."""


def get_chat(chat_id: int) -> dict:
    if chat_id not in chats:
        chats[chat_id] = {"messages": [], "model": DEFAULT_MODEL, "system": None}
    return chats[chat_id]


def is_allowed(user_id: int) -> bool:
    return not ALLOWED_IDS or user_id in ALLOWED_IDS


def run_command(command: str) -> str:
    """Execute a shell command and return output."""
    log.info("Executing: %s", command)
    try:
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=COMMAND_TIMEOUT,
        )
        output = result.stdout
        if result.stderr:
            output += "\n" + result.stderr
        output = output.strip()
        if len(output) > 4000:
            output = output[:4000] + "\n... (truncated)"
        return output or "(no output)"
    except subprocess.TimeoutExpired:
        return f"(command timed out after {COMMAND_TIMEOUT}s)"
    except Exception as e:
        return f"(error: {e})"


def extract_commands(text: str) -> list[str]:
    """Extract all <cmd>...</cmd> commands from model output."""
    return [m.strip() for m in CMD_PATTERN.findall(text) if m.strip()]


async def ollama_chat_stream(messages: list, model: str):
    """Stream a chat response from Ollama. Yields content tokens."""
    options = {}
    if model.startswith("qwen3"):
        options["num_ctx"] = 8192

    payload = {
        "model": model,
        "messages": messages,
        "stream": True,
        "options": options,
    }

    async with httpx.AsyncClient(timeout=httpx.Timeout(300, connect=10)) as client:
        async with client.stream("POST", f"{OLLAMA_URL}/api/chat", json=payload) as resp:
            resp.raise_for_status()
            async for line in resp.aiter_lines():
                if not line.strip():
                    continue
                chunk = json.loads(line)
                token = chunk.get("message", {}).get("content", "")
                if token:
                    yield token
                if chunk.get("done"):
                    return


async def send_msg(chat_id: int, text: str, bot) -> None:
    """Send a new message, splitting if over Telegram's 4096 char limit."""
    if not text.strip():
        return
    for i in range(0, len(text), 4000):
        await bot.send_message(chat_id=chat_id, text=text[i:i+4000])


async def agent_respond(messages: list, model: str, chat_id: int, bot) -> str:
    """
    Agent loop: stream model response, if it contains <cmd> tags,
    execute commands, feed results back, and loop.
    Each step is sent as a separate message so the user sees the full thinking.
    Returns the final text to store in history.
    """
    all_responses = []

    for round_num in range(MAX_TOOL_ROUNDS):
        # Stream the model response into a live message
        full_text = ""
        last_edit = 0.0
        live_msg = await bot.send_message(chat_id=chat_id, text="...")

        async for token in ollama_chat_stream(messages, model):
            full_text += token
            now = time.monotonic()
            if now - last_edit >= EDIT_INTERVAL:
                display = format_display(full_text, running=True)
                try:
                    await live_msg.edit_text(display + " ▍")
                except Exception:
                    pass
                last_edit = now

        if not full_text.strip():
            try:
                await live_msg.edit_text("(empty response)")
            except Exception:
                pass
            break

        # Finalize the streamed message
        display = format_display(full_text)
        try:
            await live_msg.edit_text(display)
        except Exception:
            pass

        # Check for commands in the response
        commands = extract_commands(full_text)

        if not commands:
            # No commands — this is the final response
            all_responses.append(full_text)
            break

        # Model wants to run commands
        all_responses.append(full_text)
        messages.append({"role": "assistant", "content": full_text})

        results_text = ""
        for cmd in commands:
            # Send command execution as its own message
            exec_msg = await bot.send_message(chat_id=chat_id, text=f"$ {cmd}\nRunning...")

            output = await asyncio.to_thread(run_command, cmd)
            results_text += f"Command: {cmd}\nOutput:\n{output}\n\n"
            log.info("Command output for '%s': %s", cmd, output[:200])

            # Update with the output
            output_display = f"$ {cmd}\n\n{output}"
            if len(output_display) > 4000:
                output_display = output_display[:4000] + "\n... (truncated)"
            try:
                await exec_msg.edit_text(output_display)
            except Exception:
                pass

        # Feed results back to the model
        messages.append({
            "role": "user",
            "content": f"[COMMAND RESULTS]\n{results_text}\n[END RESULTS]\nNow summarize the results for me clearly.",
        })
    else:
        all_responses.append("(max tool rounds reached)")
        await bot.send_message(chat_id=chat_id, text="(max tool rounds reached)")

    final = all_responses[-1] if all_responses else "(empty response)"
    return final


def format_display(text: str, running: bool = False) -> str:
    """Clean up <cmd> tags for display to user."""
    def replace_cmd(m):
        cmd = m.group(1).strip()
        if running:
            return f"[running: {cmd}]"
        return f"$ {cmd}"
    return CMD_PATTERN.sub(replace_cmd, text)


# --- Handlers ---

async def cmd_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_allowed(update.effective_user.id):
        await update.message.reply_text("Not authorised.")
        return
    chat = get_chat(update.effective_chat.id)
    await update.message.reply_text(
        f"Homeserver Agent ready. Model: {chat['model']}\n\n"
        "I can check server resources, container status, logs, and more — just ask in natural language.\n\n"
        "Commands:\n"
        "/reset — clear conversation\n"
        "/model <name> — switch model\n"
        "/models — list available models\n"
        "/system <prompt> — set system prompt\n\n"
        "Try: \"How much memory is each container using?\""
    )


async def cmd_reset(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_allowed(update.effective_user.id):
        return
    chat = get_chat(update.effective_chat.id)
    chat["messages"] = []
    await update.message.reply_text("Conversation cleared.")


async def cmd_model(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_allowed(update.effective_user.id):
        return
    chat = get_chat(update.effective_chat.id)
    args = (update.message.text or "").split(maxsplit=1)
    if len(args) < 2:
        await update.message.reply_text(f"Current model: {chat['model']}")
        return
    new_model = args[1].strip()
    chat["model"] = new_model
    chat["messages"] = []
    await update.message.reply_text(f"Model switched to: {new_model}\nConversation cleared.")


async def cmd_models(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_allowed(update.effective_user.id):
        return
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(f"{OLLAMA_URL}/api/tags")
            resp.raise_for_status()
            models = resp.json().get("models", [])
        if not models:
            await update.message.reply_text("No models found on Ollama.")
            return
        lines = [f"• {m['name']} ({m['details'].get('parameter_size', '?')})" for m in models]
        await update.message.reply_text("Available models:\n" + "\n".join(lines))
    except Exception as e:
        await update.message.reply_text(f"Error fetching models: {e}")


async def cmd_system(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_allowed(update.effective_user.id):
        return
    chat = get_chat(update.effective_chat.id)
    args = (update.message.text or "").split(maxsplit=1)
    if len(args) < 2:
        current = chat["system"] or "(default homeserver assistant)"
        await update.message.reply_text(f"Current system prompt: {current}")
        return
    chat["system"] = args[1].strip()
    chat["messages"] = []
    await update.message.reply_text("System prompt updated. Conversation cleared.")


async def handle_message(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_allowed(update.effective_user.id):
        await update.message.reply_text("Not authorised.")
        return

    user_text = update.message.text
    if not user_text:
        return

    chat = get_chat(update.effective_chat.id)
    chat["messages"].append({"role": "user", "content": user_text})

    # Build messages with system prompt
    system = chat["system"] or SYSTEM_PROMPT
    messages = [{"role": "system", "content": system}] + list(chat["messages"])

    # For qwen3, suppress thinking
    if chat["model"].startswith("qwen3"):
        if messages[-1]["role"] == "user":
            messages[-1] = {**messages[-1], "content": "/no_think " + messages[-1]["content"]}

    await ctx.bot.send_chat_action(chat_id=update.effective_chat.id, action=ChatAction.TYPING)

    try:
        final_text = await agent_respond(
            messages, chat["model"], update.effective_chat.id, ctx.bot
        )

        if final_text.strip():
            chat["messages"].append({"role": "assistant", "content": final_text})
        else:
            await update.message.reply_text("(empty response)")

    except httpx.ConnectError:
        await update.message.reply_text("Could not connect to Ollama. Is it running?")
        chat["messages"].pop()
    except httpx.HTTPStatusError as e:
        error_msg = f"Ollama error: {e.response.status_code}"
        try:
            body = e.response.json()
            error_msg += f" — {body.get('error', '')}"
        except Exception:
            pass
        await update.message.reply_text(error_msg)
        chat["messages"].pop()
    except Exception as e:
        log.exception("Unexpected error during chat")
        await update.message.reply_text(f"Error: {e}")
        chat["messages"].pop()

    # Trim history
    if len(chat["messages"]) > 40:
        chat["messages"] = chat["messages"][-40:]


def main() -> None:
    log.info("Starting Telegram Ollama Agent")
    log.info("Ollama URL: %s", OLLAMA_URL)
    log.info("Default model: %s", DEFAULT_MODEL)
    log.info("Allowed user IDs: %s", ALLOWED_IDS or "all")

    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("reset", cmd_reset))
    app.add_handler(CommandHandler("model", cmd_model))
    app.add_handler(CommandHandler("models", cmd_models))
    app.add_handler(CommandHandler("system", cmd_system))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message))

    app.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
