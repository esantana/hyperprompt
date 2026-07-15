---
description: Lê um arquivo de texto longo como imagem PNG (via hyperprompt.sh) para pagar ~4x menos tokens
---
Leia o arquivo `$ARGUMENTS` pelo funil de imagem, para economizar tokens:

1. Rode `./hyperprompt.sh -o <scratchpad>/hyperread.png < $ARGUMENTS` (use o diretório de scratchpad da sessão para o PNG).
2. Se o texto for longo, o script pagina em `hyperread-1.png`, `hyperread-2.png`, ... — leia todas as páginas.
3. Leia o(s) PNG(s) com a ferramenta Read e use o conteúdo como se tivesse lido o arquivo de texto original.
4. NÃO leia o arquivo de texto original — o objetivo é pagar tokens de imagem (lado²/750 ≈ 4x menos que o texto).
5. Confirme na saída do script a linha "quadrante lossless: ok" e reporte a economia estimada ao usuário.

Restrições (nesses casos leia o arquivo original normalmente e avise o usuário):
- Arquivos que serão editados nesta sessão — a ferramenta Edit exige Read do arquivo real.
- Quando números de linha exatos importam (referências código:linha, diffs).
- Arquivos com menos de ~2.000 caracteres — abaixo disso a imagem custa igual ou mais.
