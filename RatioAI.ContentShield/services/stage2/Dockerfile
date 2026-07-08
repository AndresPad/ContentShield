ARG BASE_IMAGE=ratioaidev.azurecr.io/contentshield-stage2:v1
FROM ${BASE_IMAGE}

ARG EXTRA_PIP_PACKAGES=""
RUN if [ -n "$EXTRA_PIP_PACKAGES" ]; then python3 -m pip install --no-cache-dir $EXTRA_PIP_PACKAGES; fi

WORKDIR /workspace

COPY . /tmp/stage2-overlay
RUN rm -rf /workspace/stage2 \
    && cp -r /tmp/stage2-overlay/src/stage2 /workspace/stage2 \
    && mkdir -p /workspace/prompts /workspace/scripts \
    && cp /tmp/stage2-overlay/prompts/pi-classifier-v6.txt /workspace/prompts/pi-classifier-v6.txt \
    && cp /tmp/stage2-overlay/prompts/pi-reason-v1.txt /workspace/prompts/pi-reason-v1.txt \
    && cp /tmp/stage2-overlay/deploy/scripts/start-vllm.sh /workspace/scripts/start-vllm.sh \
    && sed -i 's/\r$//' /workspace/scripts/start-vllm.sh \
    && chmod +x /workspace/scripts/start-vllm.sh \
    && rm -rf /tmp/stage2-overlay

ENV PYTHONPATH=/workspace
ENV PROMPT_PATH=/workspace/prompts/pi-classifier-v6.txt
ENV REASON_PROMPT_PATH=/workspace/prompts/pi-reason-v1.txt
ENV ENABLE_STAGE2_REASON=true
ENV MAX_REASON_TOKENS=256
ENV PYTHONUNBUFFERED=1

EXPOSE 8080

ENTRYPOINT ["/workspace/scripts/start-vllm.sh"]
