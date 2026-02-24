FROM node:22-slim

# Instalar dependencias del sistema
RUN apt-get update && apt-get install -y \
    git \
    curl \
    bash \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Instalar opencode globalmente
RUN npm install -g opencode-ai

# Directorio de trabajo del proyecto (montado como volumen)
WORKDIR /workspace

# Exponer puerto por defecto de opencode web
EXPOSE 4096

# Variables de entorno con defaults seguros
ENV OPENCODE_SERVER_PASSWORD=""
ENV OPENCODE_SERVER_USERNAME="opencode"

# Arranca opencode en modo web, escuchando en todas las interfaces
CMD ["opencode", "web", "--port", "4096", "--hostname", "0.0.0.0"]
