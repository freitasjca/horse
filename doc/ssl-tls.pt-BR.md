# Configuração de SSL/TLS (HTTPS)

Este guia orienta sobre como habilitar a criptografia de dados (HTTPS) em aplicações desenvolvidas com o framework **Horse**, cobrindo os diferentes provedores de transporte disponíveis.

---

## 1. Por que usar SSL/TLS diretamente na aplicação?

Habilitar HTTPS garante que todos os dados transmitidos entre o cliente e a API (como cabeçalhos de autenticação, dados de cartões de crédito e credenciais de usuários) sejam criptografados, protegendo a API contra ataques do tipo *man-in-the-middle* (MITF).

No Horse, dependendo do **Provider de Transporte** escolhido, a configuração de certificados SSL/TLS varia:

---

## 2. Configurando SSL/TLS no Provider Padrão (Indy)

O Indy (Provider padrão do Horse) realiza o gerenciamento de SSL/TLS utilizando a biblioteca OpenSSL (geralmente na versão 1.0.2).

### Pré-requisitos:
*   As DLLs do OpenSSL (`ssleay32.dll` e `libeay32.dll`) compatíveis com a arquitetura do seu executável (32 ou 64 bits) devem estar na mesma pasta da aplicação ou no Path do sistema.
*   Um arquivo de Certificado (ex: `server.crt`) e uma Chave Privada (ex: `server.key`) no formato PEM.

### Exemplo de Configuração:
Configure o handler suportado por `THorse.IOHandleSSL`. O padrão passa a ser somente TLS 1.2; veja a [política TLS do Indy](indy-tls-policy.pt-BR.md) para compatibilidade e negociação.

```pascal
uses
  Horse,
  IdSSLOpenSSL; // Necessário incluir esta unit do Indy

begin
  THorse.IOHandleSSL
    .CertFile('caminho/para/o/certificado.crt')
    .KeyFile('caminho/para/a/chave.key')
    .SSLVersions([sslvTLSv1_2]);

  THorse.Listen(9000);
end;
```

---

## 3. Configurando SSL/TLS no Provider HTTP.sys (Windows Nativo)

O provider HttpSys embutido atende apenas HTTP. Ele não oferece HTTPS atualmente; vincular um certificado com `netsh` não altera essa capacidade. Utilize terminação TLS em um proxy reverso ou um provider com suporte HTTPS documentado.

Consulte a [matriz de providers](providers.pt-BR.md) antes de escolher o transporte.

---

## 4. Prática Recomendada em Ambientes Corporativos: Proxy Reverso

> [!TIP]
> Embora seja possível configurar SSL/TLS diretamente nos executáveis Delphi, em ambientes corporativos e de alta concorrência a prática recomendada de mercado é usar um **Proxy Reverso** (como **Nginx**, **Caddy** ou **Apache**) à frente do seu servidor Horse.

### Vantagens do Proxy Reverso:
1.  **Segurança e Isolação**: O Nginx/Caddy intercepta as requisições públicas expostas e repassa o tráfego de forma limpa (geralmente via HTTP local) para o executável do Horse.
2.  **Renovação Automática**: Servidores de borda modernos como o Caddy gerenciam e renovam automaticamente certificados Let's Encrypt válidos sem que você precise parar ou recompilar sua aplicação Delphi.
3.  **Desempenho**: Reduz o overhead de CPU do seu executável Delphi que não precisará gastar processamento com o aperto de mãos (*TLS Handshake*).

```
[ Cliente ]  --- ( HTTPS / Porta 443 ) --->  [ Nginx / Caddy ]  --- ( HTTP / Porta 9000 ) --->  [ API Horse ]
```
