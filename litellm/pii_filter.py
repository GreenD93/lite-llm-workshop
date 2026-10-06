"""Workshop Custom Guardrail: masking Korea-format PII.

Before the request leaves for the model (pre_call), finds resident
registration numbers and mobile phone numbers (Korean formats, as an
example of country-specific PII) in message bodies with regexes and
replaces them with masking tokens. Unlike Bedrock Guardrails this runs
inside the gateway process, so in-house rules (regexes, deny-word
dictionaries, internal API lookups) can be written freely in code.
"""
import re

from litellm.caching.caching import DualCache
from litellm.integrations.custom_guardrail import CustomGuardrail
from litellm.proxy._types import UserAPIKeyAuth

PII_PATTERNS = [
    (re.compile(r"\d{6}[-\s]?[1-4]\d{6}"), "[KR-RESIDENT-ID]"),
    (re.compile(r"01[016789][-\s]?\d{3,4}[-\s]?\d{4}"), "[KR-MOBILE]"),
]


def mask_pii(text: str) -> str:
    for pattern, token in PII_PATTERNS:
        text = pattern.sub(token, text)
    return text


class PiiMaskingGuardrail(CustomGuardrail):
    async def async_pre_call_hook(
        self,
        user_api_key_dict: UserAPIKeyAuth,
        cache: DualCache,
        data: dict,
        call_type: str,
    ):
        messages = list(data.get("messages") or [])
        input_data = data.get("input")
        if isinstance(input_data, str):
            data["input"] = mask_pii(input_data)
        elif isinstance(input_data, list):
            messages.extend(item for item in input_data if isinstance(item, dict))
        for message in messages:
            content = message.get("content")
            if isinstance(content, str):
                message["content"] = mask_pii(content)
            elif isinstance(content, list):  # multipart (text + image) format
                for part in content:
                    if isinstance(part, dict) and isinstance(part.get("text"), str):
                        part["text"] = mask_pii(part["text"])
        return data
