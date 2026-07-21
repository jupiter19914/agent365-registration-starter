FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py agent.py ./
COPY .env.example .env.example

EXPOSE 3978

HEALTHCHECK --interval=30s --timeout=3s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:3978/health')" || exit 1

CMD ["python", "app.py"]
