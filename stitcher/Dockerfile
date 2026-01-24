FROM python:3.12-slim

RUN pip install --no-cache-dir python-dateutil

WORKDIR /app
COPY stitcher.py /app/stitcher.py

CMD ["python", "/app/stitcher.py"]