# Política de protocolos TLS no Indy

Os providers Delphi Indy embutidos (Console, Daemon e VCL) configuram HTTPS por
`THorse.IOHandleSSL`. Novos handlers usam **somente TLS 1.2** por padrão, em vez
de herdar o padrão do Indy que permite apenas TLS 1.0.

```pascal
uses Horse, IdSSLOpenSSL;

begin
  THorse.IOHandleSSL
    .CertFile('server.crt')
    .KeyFile('server.key')
    .SSLVersions([sslvTLSv1_2]);
  THorse.Listen(9000);
end;
```

`Method(...)` e `SSLVersions(...)` são duas representações da mesma política.
Vale a última chamada, com a normalização do próprio Indy instalado. Por exemplo,
`SSLVersions([sslvTLSv1]).Method(sslvTLSv1_2)` passa a selecionar realmente TLS
1.2, sem manter silenciosamente TLS 1.0 ao inicializar o provider.

`SSLVersions` é um conjunto não ordenado de versões permitidas, não uma lista
de preferência ou tentativas. Com várias versões habilitadas, Indy/OpenSSL
negocia o protocolo mais alto suportado por ambos; o Horse não percorre os
elementos na ordem do enum. `sslvSSLv23` é o seletor histórico de negociação do
Indy, não TLS 1.3, e mantém a semântica legada do Indy, inclusive a permissão para
versões SSL obsoletas. Prefira versões explícitas.

## Compatibilidade e escopo

Aplicações que dependiam implicitamente de TLS 1.0 precisam atualizar os clientes.
Configurações legadas explícitas continuam aceitas por compatibilidade, mas
habilitar TLS 1.0/1.1 é desaconselhado. HTTP sem TLS, providers externos e campos
TLS do record `THorseProviderConfig` não são alterados.

O adaptador padrão `IdSSLOpenSSL` suporta no máximo TLS 1.2 e exige binários
OpenSSL compatíveis. Este acerto **não** adiciona TLS 1.3 nem atualiza o OpenSSL.
Para suporte mais recente, use um provider externo com TLS ou um proxy reverso.
HttpSys/IOCP/Epoll e os providers FPC embutidos não passam a atender HTTPS por
este acerto; vincular um certificado no sistema operacional não basta.

Veja as [capacidades dos providers](providers.pt-BR.md) e os
[testes TLS reproduzíveis](../tests/tls-policy/README.md).
