# Regressão da factory de streaming

*Leia em [English](./README.md) ou [Português (BR)](./README.pt-BR.md).*

Cobertura de regressão do PR #611. Execute na raiz do repositório:

```powershell
./tests/stream-factory/run-stream-factory.ps1
```

O runner usa os compiladores Delphi 11, 12 e 13 instalados. Cada cenário tem artefatos isolados em `benchmarks/results/`. Não encontrar compiladores é uma falha, não um teste aprovado sem execução. Outras instalações suportadas podem ser selecionadas com `-Versions`.

`StreamFactoryCheck.dpr` verifica os dois overloads: factories ausentes ou que lançam exceção deixam `IsStreaming` falso e não chamam o produtor; um writer adquirido observa o estado de streaming e fecha exatamente uma vez, mesmo quando o produtor lança exceção.

A matriz Delphi de registro compila primeiro o grafo padrão, depois recompila a **unit Horse.Response real** com cada define de provider e relinka o teste. Isso isola intencionalmente a inicialização da resposta da inicialização dos transportes externos. Cobre os defines antigos/atuais de CrossSocket e nghttp2, mORMot, ICS, IOCP, HttpSys e Epoll, além da preservação do fallback WebBroker padrão. **Não** substitui testes reais dos providers externos nem valida a ordem de inicialização das suas units.

`StreamingFailureCheck.dpr` executa dois testes HTTP DUnitX com Indy, IOCP e HttpSys, usando Tree e Radix. Os testes verificam a resposta 503 e seu corpo completo após falha na aquisição da factory ausente ou que lança exceção, em vez de um 200 vazio ou timeout. A porta **19127**, apenas no loopback IPv4, deve estar disponível; o runner nunca encerra processos alheios. A preparação aguarda o hook after-listen do provider e uma requisição HTTP de prontidão. O encerramento para o listener e aguarda sua thread.

A injeção da factory é global ao processo. Mantenha estes testes em seu executável dedicado, não em uma fixture de streaming bem-sucedido executada concorrentemente. Os testes existentes de NDJSON, SSE e streaming concorrente permanecem na suíte principal:

```powershell
./tests/run_delphi_tests.ps1 -Versions 22.0,23.0,37.0
```

No FPC, execute o teste compartilhado de estado da resposta e ciclo de vida, com detecção de vazamentos pelo heaptrc:

```sh
sh tests/stream-factory/run-stream-factory.sh
```

Por exemplo, no Windows com as imagens de teste FPC construídas localmente pelo repositório:

```powershell
docker run --rm -v "${PWD}:/work:ro" --entrypoint sh horse-provider-tests:fpc-3.2.2 /work/tests/stream-factory/run-stream-factory.sh
docker run --rm -v "${PWD}:/work:ro" --entrypoint sh horse-provider-tests:fpc-3.3.1 /work/tests/stream-factory/run-stream-factory.sh
```

O runner Linux exercita o grafo padrão FPC; a matriz de isolamento por define é exclusiva do Delphi. Um programa Epoll completo registra seu próprio writer, portanto esperar uma factory ausente nesse programa seria incorreto.
