#!/bin/zsh
# Agent quality benchmark: builds a scene from each prompt with one Claude Code turn (`vmotion chat`), then
# scores it with the lint + critic (`vmotion review`) and renders a contact sheet to look at.
#
#   scripts/bench/run.sh [--model m] [--name run-name] [id ...]      (no ids = every prompt)
#   scripts/bench/summary.py bench-out/<run> [bench-out/<other-run>]  → markdown table (comparison with two)
#
# Needs a built CLI (`swift build`; override with VMOTION=path) and Claude Code logged in. Output goes to
# bench-out/<run>/<id>/: scene.json, chat.log, review.json, sheet.png, frames/ (what the agent looked at).
set -u
HERE=${0:a:h}
ROOT=${HERE:h:h}
VMOTION=${VMOTION:-$ROOT/.build/debug/vmotion}
MODEL=""
RUN=$(date +%Y%m%d-%H%M)
IDS=()
while (( $# )); do
  case $1 in
    --model) MODEL=$2; shift 2 ;;
    --name) RUN=$2; shift 2 ;;
    *) IDS+=($1); shift ;;
  esac
done
[[ -x $VMOTION ]] || { echo "vmotion not found at $VMOTION (swift build, or VMOTION=path)" >&2; exit 1; }
OUT=${BENCH_OUT:-$ROOT/bench-out}/$RUN
mkdir -p "$OUT"
PROMPTS=$HERE/prompts.json
if (( ${#IDS} == 0 )); then
  IDS=($(python3 -c 'import json,sys; print(" ".join(p["id"] for p in json.load(open(sys.argv[1]))))' "$PROMPTS"))
fi
echo "run $RUN → $OUT"
for id in $IDS; do
  dir=$OUT/$id
  mkdir -p "$dir/frames"
  # The prompt and an empty scene of its size.
  python3 - "$PROMPTS" "$id" "$dir" <<'EOF'
import json, sys
prompts, id, d = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
p = next((p for p in prompts if p["id"] == id), None)
if p is None: sys.exit(f"no prompt {id}")
open(f"{d}/prompt.txt", "w").write(p["prompt"])
json.dump({"width": p["width"], "height": p["height"], "duration": p["duration"], "fps": 30,
           "background": "#101218", "layers": []}, open(f"{d}/scene.json", "w"))
EOF
  [[ -f $dir/prompt.txt ]] || continue
  prompt=$(<"$dir/prompt.txt")
  echo "== $id"
  t0=$(date +%s)
  ( cd "$dir" && VEYMOTION_SCENE="$dir/scene.json" VEYMOTION_AGENT_DIR="$dir" VEYMOTION_FRAMES_DIR="$dir/frames" \
      "$VMOTION" chat ${MODEL:+--model "$MODEL"} "$prompt" > "$dir/chat.log" 2>&1 )
  echo "   chat: $(( $(date +%s) - t0 ))s · $(grep -E '^· (done|error)' "$dir/chat.log" | tail -1)"
  # Score it. The critic is a second Claude Code call; --lint-only is the cheap variant.
  VEYMOTION_AGENT_DIR="$dir" "$VMOTION" review "$dir/scene.json" --brief "$prompt" --json > "$dir/review.json" 2> "$dir/review.err" \
    || echo "   review failed: $(tail -1 "$dir/review.err")"
  # A contact sheet of 8 frames across the piece.
  times=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])).get("duration",5); print(json.dumps([round(d*(i+0.5)/8,2) for i in range(8)]))' "$dir/scene.json")
  VEYMOTION_FRAMES_DIR="$dir" "$VMOTION" render_frames "{\"times\":$times,\"columns\":4,\"scale\":0.5}" --scene "$dir/scene.json" > "$dir/sheet.log" 2>&1
  sheet=$(ls "$dir"/render_frames-*.png 2>/dev/null | head -1)
  [[ -n $sheet ]] && mv "$sheet" "$dir/sheet.png"
done
python3 "$HERE/summary.py" "$OUT" | tee "$OUT/summary.md"
