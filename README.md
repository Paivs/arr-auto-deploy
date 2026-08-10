# ARR VM Docker Stack

Este repo mantem um instalador para rodar um stack ARR em uma VM Debian no
Proxmox VE, usando Docker Compose.

## Arquitetura

Decisao atual:

- Criar uma VM Debian 13 `trixie` em vez de varios LXCs.
- Usar bridge Proxmox normal, por padrao `vmbr0`.
- Instalar Docker Engine dentro da VM.
- Rodar o stack em `/opt/arr/compose.yaml`.
- Guardar configuracoes em `/data/configs`.
- Guardar downloads em `/data/downloads`.
- Guardar midia em `/data/media`.
- Deixar VPN fora da primeira versao.

O script usa a imagem oficial Debian 13 `generic`:

```text
https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2
```

A imagem `generic` foi escolhida em vez de `genericcloud` para priorizar
compatibilidade em ambiente Proxmox/local QEMU.

## Servicos

O compose inicial inclui:

- Prowlarr: `9696`
- Sonarr: `8989`
- Radarr: `7878`
- Lidarr: `8686`
- Bazarr: `6767`
- qBittorrent: `8090`

Outros apps que podem fazer sentido depois:

- Readarr, para livros.
- Overseerr/Jellyseerr, para pedidos de midia.
- Unpackerr, para extrair releases automaticamente.
- Gluetun, para isolar qBittorrent via VPN.

## Fluxo Do Script

Execute no node Proxmox:

```bash
sudo ./arr-vm-docker-stack.sh
```

O script:

1. Valida comandos Proxmox e dependencias locais.
2. Pergunta VMID, nome, CPU, RAM, disco, storage e bridge.
3. Pergunta se a VM usara DHCP ou IP estatico.
4. Baixa a cloud image Debian 13, se ainda nao existir.
5. Gera uma chave SSH de provisionamento em `/var/lib/arr-vm-docker-stack`.
6. Cria a VM com cloud-init.
7. Inicia a VM e espera SSH responder.
8. Instala Docker Engine, Compose plugin e qemu-guest-agent.
9. Gera `/opt/arr/.env` e `/opt/arr/compose.yaml`.
10. Executa `docker compose pull` e `docker compose up -d`.
11. Escreve um resumo em `/var/lib/arr-vm-docker-stack/summary.txt`.

## Rede

Para `VM_IP_MODE=static`, o script configura o IP via cloud-init.

Para `VM_IP_MODE=dhcp`, o script ainda precisa que voce informe o IP reservado
no roteador/DHCP, porque ele precisa saber onde conectar por SSH para finalizar
o bootstrap.

## Observacoes

O qBittorrent pode gerar senha temporaria na primeira inicializacao. Se a senha
nao aparecer na tela inicial, confira os logs:

```bash
docker logs qbittorrent
```

VPN/killswitch sera um incremento separado para evitar misturar provider,
credenciais e roteamento com a criacao inicial da VM.

## Retomar Bootstrap

Se a VM ja foi criada, mas o bootstrap falhou ao baixar imagens Docker, rode
novamente em modo `bootstrap`:

```bash
sudo ACTION=bootstrap VMID=120 VM_IP=192.168.1.50 ./arr-vm-docker-stack.sh
```

Use o mesmo `VMID`, IP, usuario cloud-init e `WORK_DIR` da execucao original.
Por padrao, o `WORK_DIR` e:

```text
/var/lib/arr-vm-docker-stack
```

Esse modo nao recria a VM. Ele reutiliza a chave SSH de provisionamento, conecta
na VM existente, regrava o compose e tenta baixar as imagens uma por vez com
retry.
