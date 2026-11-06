#!/usr/bin/env bash
# aws-vault exec rails-dev -- accept_bedrock_offers.sh --accept haiku-5-5
# Show a Bedrock model's offer status; --accept accepts it. Searches ACTIVE text models of PROVIDERS (or --vendor).
# Several matches are only listed. --vendor with no MODEL lists that vendor's models. Region comes from aws-vault.
set -euo pipefail

PROVIDERS=(anthropic openai google meta mistral) # companies in our product

usage() {
  echo "Usage: aws-vault exec PROFILE -- $0 [--accept] [--vendor VENDOR]... [MODEL...]" >&2
  exit 1
}

ACCEPT=false
VENDORS=()
NAMES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --accept) ACCEPT=true ;;
    --vendor) [[ $# -gt 1 ]] || usage; VENDORS+=("$2"); shift ;;
    -*)       usage ;;
    *)        NAMES+=("$1") ;;
  esac
  shift
done
[[ ${#VENDORS[@]} -eq 0 ]] || PROVIDERS=("${VENDORS[@]}")
[[ ${#NAMES[@]} -gt 0 || ${#VENDORS[@]} -gt 0 ]] || usage
[[ ${#NAMES[@]} -gt 0 ]] || NAMES=("")

ACTIVE=$(aws bedrock list-foundation-models --by-output-modality TEXT \
  --query "modelSummaries[?modelLifecycle.status=='ACTIVE'].modelId" --output text | tr '\t' '\n' \
  | grep -E "^($(IFS='|'; echo "${PROVIDERS[*]}"))\." || true)

for NAME in "${NAMES[@]}"; do
  echo "== ${NAME:-${PROVIDERS[*]}}"
  MATCHES=$(grep -F -- "$NAME" <<<"$ACTIVE" || true)
  if [[ $(grep -c . <<<"$MATCHES") -ne 1 ]]; then
    sed 's/^/  /' <<<"${MATCHES:-no ACTIVE model matches}"
    continue
  fi
  STATUS=$(aws bedrock get-foundation-model-availability --model-id "$MATCHES" --query 'agreementAvailability.status' --output text)
  echo "  $MATCHES: $STATUS"
  if [[ "$ACCEPT" == true && "$STATUS" != "AVAILABLE" ]]; then
    TOKEN=$(aws bedrock list-foundation-model-agreement-offers --model-id "$MATCHES" --query 'offers[0].offerToken' --output text)
    aws bedrock create-foundation-model-agreement --model-id "$MATCHES" --offer-token "$TOKEN" >/dev/null
    echo "  accepted (access can take ~5 minutes)"
  fi
done
