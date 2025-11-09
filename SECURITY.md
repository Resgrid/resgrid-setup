# SECURITY POLICY

## Reporting a Security Vulnerability

If you discover a security vulnerability in this project, please report it privately to:
- **Email:** security@ambipar.ca
- **Do NOT** create a public GitHub issue for security vulnerabilities

## Secure Configuration

### Environment Variables

This project uses environment variables for all sensitive configuration. **Never commit actual credentials to version control.**

### Required Security Steps

1. **Copy Example Files**
   ```bash
   cp .env.example .env
   cp .env.ambipar.example .env.ambipar
   ```

2. **Update with Real Credentials**
   - Edit `.env` with your database passwords
   - Edit `.env.ambipar` with your API keys
   - Use strong, unique passwords for each service

3. **Verify .gitignore**
   ```bash
   # These files should NEVER be committed:
   .env
   .env.ambipar
   .env.local
   .env.production
   docker-data/caddy/data/caddy/certificates/
   docker-data/caddy/data/caddy/pki/
   *.key
   *.crt
   *.pem
   ```

## Secrets Management Best Practices

### Development Environment

For local development, use `.env` files (already gitignored):

```bash
# .env
POSTGRES_PASSWORD=your-secure-dev-password
REDIS_PASSWORD=your-secure-dev-password
RABBITMQ_PASSWORD=your-secure-dev-password
```

### Production Environment

For production, use one of these approaches:

#### Option 1: Environment Variables (Recommended)
```bash
# Set directly in your deployment environment
export POSTGRES_PASSWORD="$(openssl rand -base64 32)"
export REDIS_PASSWORD="$(openssl rand -base64 32)"
export RABBITMQ_PASSWORD="$(openssl rand -base64 32)"
```

#### Option 2: Docker Secrets
```yaml
# docker-compose.prod.yml
services:
  db:
    environment:
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    secrets:
      - db_password

secrets:
  db_password:
    external: true
```

#### Option 3: Cloud Secret Management
- **AWS:** AWS Secrets Manager
- **Azure:** Azure Key Vault
- **GCP:** Google Cloud Secret Manager

## Password Requirements

### Generate Secure Passwords

```bash
# PostgreSQL password (32 characters)
openssl rand -base64 32

# Redis password (24 characters)
openssl rand -base64 24

# RabbitMQ password (24 characters)
openssl rand -base64 24
```

### Minimum Requirements

- **Length:** At least 16 characters
- **Complexity:** Mix of uppercase, lowercase, numbers, symbols
- **Uniqueness:** Different password for each service
- **Rotation:** Change passwords every 90 days in production

## API Keys & Tokens

### OpenAI API Key
- Obtain from: https://platform.openai.com/api-keys
- Set usage limits in OpenAI dashboard
- Monitor usage regularly
- **Never commit:** Store in `.env.ambipar`

### Azure OpenAI
- Use managed identities when possible
- Rotate keys every 90 days
- Enable Azure Key Vault integration

### SharePoint Integration
- Use Azure AD app registration
- Grant minimum required permissions
- Enable multi-factor authentication
- Use certificate authentication in production

## SSL/TLS Certificates

### Development (Self-Signed)
```bash
# Caddy generates self-signed certificates automatically
# These are stored in docker-data/caddy/data/ (gitignored)
# Safe for local development only
```

### Production (Let's Encrypt)
```bash
# Caddy obtains real SSL certificates automatically
# Set in .env:
NGINX_LETSENCRYPT_EMAIL=admin@ambipar.ca

# Certificates stored in docker-data/caddy/data/
# Renewed automatically by Caddy
```

## Database Security

### PostgreSQL Hardening

1. **Strong Passwords**
   ```bash
   POSTGRES_PASSWORD=$(openssl rand -base64 32)
   ```

2. **Network Isolation**
   - Use Docker internal networks
   - Don't expose port 5432 to public internet
   - Use SSH tunnel or VPN for remote access

3. **Backup Encryption**
   ```bash
   # Encrypted backups
   pg_dump resgrid | gpg --encrypt > backup.sql.gpg
   ```

4. **Regular Updates**
   ```bash
   # Keep PostgreSQL updated
   docker pull postgres:16
   ```

### Redis Security

1. **Authentication Required**
   ```yaml
   command: redis-server --requirepass ${REDIS_PASSWORD}
   ```

2. **Disable Dangerous Commands**
   ```yaml
   command: redis-server --requirepass ${REDIS_PASSWORD} --rename-command FLUSHALL ""
   ```

3. **Network Binding**
   - Only bind to internal Docker network
   - Never expose to public internet

## Dependency Security

### Regular Updates

```bash
# Update Docker images
docker-compose pull

# Check for vulnerabilities
docker scan resgridllc/resgridwebservices:latest

# Update .NET packages
dotnet outdated
dotnet list package --vulnerable
```

### Automated Scanning

Enable these GitHub features:
- ✅ Dependabot alerts
- ✅ Code scanning (CodeQL)
- ✅ Secret scanning (GitGuardian)
- ✅ Dependency review

## Incident Response

If credentials are accidentally committed:

1. **Immediately Revoke**
   - Rotate all exposed passwords
   - Revoke API keys
   - Generate new certificates

2. **Remove from Git History**
   ```bash
   # Use BFG Repo-Cleaner or git-filter-repo
   git filter-repo --path .env --invert-paths
   ```

3. **Force Push (Carefully)**
   ```bash
   git push origin --force --all
   ```

4. **Notify Team**
   - Alert all team members
   - Document the incident
   - Update security procedures

## Compliance

This system handles sensitive data. Ensure compliance with:

- **PIPEDA** (Personal Information Protection)
- **FOIPPA** (BC Freedom of Information)
- **WorkSafeBC** regulations
- **Industry-specific** standards

## Audit Logging

Enable audit logging for:
- Authentication attempts
- API key usage
- Database access
- Configuration changes
- AI service calls

## Security Checklist

### Before First Deployment

- [ ] All passwords changed from defaults
- [ ] API keys configured and limits set
- [ ] SSL certificates configured
- [ ] Firewall rules configured
- [ ] Backup strategy implemented
- [ ] Monitoring/alerting configured
- [ ] Security scanning enabled
- [ ] Team trained on security practices

### Regular Maintenance

- [ ] Review access logs weekly
- [ ] Rotate passwords quarterly
- [ ] Update dependencies monthly
- [ ] Test backups monthly
- [ ] Review audit logs weekly
- [ ] Update documentation as needed

## Contact

For security concerns:
- **Email:** security@ambipar.ca
- **Emergency:** [Your emergency contact]

---

**Last Updated:** November 2025
**Maintained By:** Ambipar Security Team
