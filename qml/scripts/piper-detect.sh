#!/usr/bin/env bash
# Find a runnable Piper binary and the best male voice that is fast enough for real-time speech.
#   piper-detect.sh <configured-binary> <configured-model>
# Prints four lines: binary, model, sample_rate, rtf   (empty binary/model = none usable)
# Voices are benchmarked once (real-time factor = synthesis time / audio length) and cached in
# ${XDG_STATE_HOME:-~/.local/state}/clippy-ai/tts-bench.txt; voices slower than real time are skipped.
cfg_bin=$1 cfg_model=$2
max_rtf=0.9
cache="${XDG_STATE_HOME:-$HOME/.local/state}/clippy-ai/tts-bench.txt"
mkdir -p "$(dirname "$cache")"; touch "$cache"

bin=""
for c in "$cfg_bin" "$HOME/.local/share/clippy-ai/piper/piper" "/opt/ttos/clippy-ai/piper/piper" \
         "$HOME/.local/share/ttos/assistant/piper/runtime/piper" "$(command -v piper)"; do
    [ -n "$c" ] && [ -x "$c" ] && LD_LIBRARY_PATH="$(dirname "$c")" "$c" --help >/dev/null 2>&1 && { bin=$c; break; }
done
[ -z "$bin" ] && { printf '\n\n\n\n'; exit 0; }

rate_of() { local r=22050; [ -f "$1.json" ] && r=$(grep -o '"sample_rate": *[0-9]*' "$1.json" | grep -o '[0-9]*$'); echo "${r:-22050}"; }

rtf_of() {   # cached, else measure
    local m=$1 key; key="$m $(stat -c %s "$m")"
    local hit; hit=$(grep -F "$key " "$cache" | tail -1 | awk '{print $NF}')
    [ -n "$hit" ] && { echo "$hit"; return; }
    local rate s e bytes rtf
    rate=$(rate_of "$m"); s=$(date +%s.%N)
    bytes=$(printf 'Hello there. This is a quick speed test of the voice.' | LD_LIBRARY_PATH="$(dirname "$bin")" "$bin" --model "$m" --output-raw 2>/dev/null | wc -c)
    e=$(date +%s.%N)
    rtf=$(awk -v s="$s" -v e="$e" -v b="$bytes" -v r="$rate" 'BEGIN{a=b/2/r; if(a<=0){print 99}else printf "%.2f",(e-s)/a}')
    echo "$key $rtf" >> "$cache"; echo "$rtf"
}

# an explicitly configured model is used as-is
if [ -n "$cfg_model" ] && [ -f "$cfg_model" ]; then
    printf '%s\n%s\n%s\n%s\n' "$bin" "$cfg_model" "$(rate_of "$cfg_model")" "$(rtf_of "$cfg_model")"; exit 0
fi

# male voices, most natural first among those that run in real time
for d in "$HOME/.local/share/clippy-ai/voices" "$HOME/.local/share/ttos/assistant/piper" /usr/share/piper-voices; do
    for n in en_US-ryan-medium en_US-ryan-high en_US-joe-medium en_GB-alan-medium en_US-hfc_male-medium \
             en_GB-northern_english_male-medium en_US-ryan-low en_GB-alan-low; do
        m="$d/$n.onnx"; [ -f "$m" ] || continue
        r=$(rtf_of "$m")
        if awk -v r="$r" -v t="$max_rtf" 'BEGIN{exit !(r<=t)}'; then
            printf '%s\n%s\n%s\n%s\n' "$bin" "$m" "$(rate_of "$m")" "$r"; exit 0
        fi
    done
done
printf '%s\n\n\n\n' "$bin"      # Piper works but no suitable male voice: caller falls back to espeak-ng
