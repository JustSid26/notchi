# Prints the tab colour of every iTerm2 session as JSON, for Notchi.
# Run by Notchi with ITERM2_COOKIE / ITERM2_KEY set (obtained via AppleScript).
import json

import iterm2


async def main(connection):
    app = await iterm2.async_get_app(connection)
    out = []
    for window in app.terminal_windows:
        for tab in window.tabs:
            for session in tab.sessions:
                color = None
                try:
                    profile = await session.async_get_profile()
                    if profile.use_tab_color and profile.tab_color is not None:
                        c = profile.tab_color
                        color = [c.red, c.green, c.blue]
                except Exception:
                    pass
                out.append({"id": session.session_id, "color": color})
    print(json.dumps(out))


iterm2.run_until_complete(main)
