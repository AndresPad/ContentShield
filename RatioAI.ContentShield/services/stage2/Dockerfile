ARG BASE_IMAGE=ratioaidev.azurecr.io/contentshield-stage2:v1
FROM ${BASE_IMAGE}

ARG EXTRA_PIP_PACKAGES=""
RUN if [ -n "$EXTRA_PIP_PACKAGES" ]; then python3 -m pip install --no-cache-dir $EXTRA_PIP_PACKAGES; fi

WORKDIR /workspace

COPY src/stage2 /workspace/stage2
COPY prompts/pi-classifier-v6.txt /workspace/prompts/pi-classifier-v6.txt
COPY prompts/pi-reason-v1.txt /workspace/prompts/pi-reason-v1.txt
COPY deploy/scripts/start-vllm.sh /workspace/scripts/start-vllm.sh
RUN sed -i 's/\r$//' /workspace/scripts/start-vllm.sh \
    && chmod +x /workspace/scripts/start-vllm.sh

ENV PYTHONPATH=/workspace
ENV PROMPT_PATH=/workspace/prompts/pi-classifier-v6.txt
ENV REASON_PROMPT_PATH=/workspace/prompts/pi-reason-v1.txt
ENV PYTHONUNBUFFERED=1

EXPOSE 8080

ENTRYPOINT ["/workspace/scripts/start-vllm.sh"]
