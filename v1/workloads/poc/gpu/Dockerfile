FROM pytorch/pytorch:2.4.1-cuda12.4-cudnn9-runtime

WORKDIR /app
COPY server.py /app/server.py
ENV PORT=8080
EXPOSE 8080
CMD ["python", "/app/server.py"]
