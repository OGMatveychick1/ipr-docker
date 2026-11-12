FROM python:3.13-slim

WORKDIR /app

COPY app/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY app/app.py ./app.py

EXPOSE 8000

CMD ["python", "app.py"]
