# Agents

uiui has no agent of its own. Any agent that can run a command can ask you a question, and you answer by voice from whichever app you are in. uiui shows the text it was given, captures your voice and returns your words. It never interprets either.

Open **Settings → Agents**, turn on **Let agents ask you**, and press **Connect** beside each agent. uiui lists Claude Code, Codex and OpenCode when it finds them on this Mac.

Connecting does one thing: it adds a small skill, `uiui-ask`, to that agent's skills folder. The skill tells the agent that the `uiui ask` command exists and when to use it. It isn't a plugin or a server, and there's no account or login. **Disconnect** removes the skill. For any other agent, copy the instructions from Settings into its instructions file. `uiui ask` is a command inside the app itself, at `/Applications/uiui.app/Contents/MacOS/uiui`.

## `uiui ask`

```text
uiui ask "question" [--from name] [--timeout seconds]
uiui stats
```

The name defaults to the current folder. The default timeout is 600 seconds. Your exact words go to stdout, with your dictionary applied and no other cleanup. Nothing else goes to stdout.

| Exit code | Meaning |
| --- | --- |
| 0 | Answered |
| 2 | Wrong usage |
| 3 | Not available: uiui is not running, or Agents or the notch is off. It never launches uiui. |
| 4 | Away: the Mac is locked or asleep |
| 5 | Timed out |

If the agent exits or is stopped, its question disappears on its own.

## In the notch

- One question at a time, oldest first, with `+N` for the rest. A question never appears while you are dictating.
- **Right Option** answers (Right Command if dictation already uses Right Option). The dictation key still types at your cursor. The agent's name is visible only when words are going to that agent.
- **Hold** and release to send. **Tap** to talk freely, tap again to send. Escape discards. The time shows in the right wing. A tapped answer ends after 10 minutes and keeps its words.
- The key binds only to a question that has been visible for about half a second. A silent release sends nothing and the question stays.
- A waiting question folds to "name asks" after about 8 seconds. Point at it to read it in full.
- If the agent has gone by the time you finish, your words stay in the notch with Copy.

The socket exists only while Agents is on, and only your user can connect to it. Questions and answers are not kept in History or drafts, and are never logged. An agent may send your answer to its own service; that is up to the agent.

## Voice approvals in Claude Code

This is a recipe outside the app. uiui has no idea what an approval is: it returns your words, and the script below decides. Only a bare yes word allows the command. Any other reply goes back to Claude as your instruction, and anything uncertain falls back to Claude's normal typed prompt.

Save as `~/.claude/hooks/uiui-approve.sh` and make it executable. **Edit `families` to the commands you are happy to approve by voice.** Everything else stays on the typed prompt.

```zsh
#!/bin/zsh
setopt extended_glob
input=$(cat)
command=$(print -r -- "$input" | plutil -extract tool_input.command raw -o - - 2>/dev/null) || exit 0
families=(ls swift)

[[ -n "$command" && ${#command} -le 120 && "$command" != *$'\n'* ]] || exit 0   # Must fit in the notch.
[[ "$command" != *[\;\&\|\`\$\>\<]* ]] || exit 0                                # One plain command only.
(( ${families[(Ie)${command%% *}]} )) || exit 0

words=$(uiui ask "Run: $command" --from "${PWD:t}" --timeout 120) || exit 0
reply=${${(L)words}//[[:punct:]]/}
reply=${${reply##[[:space:]]#}%%[[:space:]]#}
[[ -n "$reply" ]] || exit 0

case "$reply" in
  yes|yeah|ok|okay|haan|han|ha|"theek hai"|"thik hai")
    print -r -- '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
    ;;
  *)
    message=${${words//\\/\\\\}//\"/\\\"}
    print -r -- "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"deny\",\"message\":\"Not run. The person replied: $message\"}}}"
    ;;
esac
```

Then add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PermissionRequest": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/.claude/hooks/uiui-approve.sh", "timeout": 130 }] }
    ]
  }
}
```

Before relying on this, test on your own voice how often "haan" and "nahi" are confused, and whether background noise can produce a yes word. This has not been measured. The check is on the first word only, so `git` would also approve `git push --force`. Keep anything with destructive subcommands out of `families`.

## Usage counts

`uiui stats` prints the last 7 days from this Mac: dictations, words, questions, answers by hold and tap, questions that went unanswered, and time to answer. Settings shows a one-line version. These are stored locally with uiui's other usage counts, are removed by **Delete everything**, and contain no question, answer or agent name. uiui sends no analytics anywhere.
