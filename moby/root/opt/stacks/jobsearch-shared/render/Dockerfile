# Markdown -> .docx (Pandoc) -> PDF (Gotenberg), and YAML -> JSON, for the
# job search pipelines' tailored CVs. Built on moby by deploy.sh.
FROM pandoc/core:3.8
RUN apk add --no-cache python3 py3-yaml
COPY server.py /srv/server.py
USER 65534
EXPOSE 8080
ENTRYPOINT ["python3", "/srv/server.py"]
