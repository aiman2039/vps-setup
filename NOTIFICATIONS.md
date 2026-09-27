 is there anyway to push notifications to phone from cli?

◆ Yes, easiest options:

  1. ntfy.sh (free, no signup) — install ntfy app, then:
    curl -d "build done" ntfy.sh/your-unique-topic

  2. Pushover ($5 once, iOS/Android) — install app, get user key + token, then:
    curl -s --form-string "token=APP_TOKEN" --form-string "user=USER_KEY" --form-string "message=done" https://api.pushover.net/1/messages.json

  3. Telegram bot (free) — create bot via BotFather, get chat id, then:
    curl -s "https://api.telegram.org/botTOKEN/sendMessage?chat_id=ID&text=done"

  4. Apprise (universal wrapper for 80+ services):
    pip install apprise
    apprise -b "build done" "ntfy://your-unique-topic"

  iPhone or Android? I can give you the 1-command setup.
