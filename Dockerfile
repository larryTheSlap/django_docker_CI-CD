FROM python:3

COPY requirement.txt requirement.txt
RUN pip install -r requirement.txt

COPY . django_dir
WORKDIR /django_dir

EXPOSE 80

ENTRYPOINT ["python", "manage.py"]
CMD ["runserver", "0.0.0.0:80"]