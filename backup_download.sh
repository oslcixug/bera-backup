#!/bin/bash

# Functions

checkcopies () {
	output=$(ls /media/backup/cixug-suxi-sug | grep .backup.tar.gz$ | wc -l)
	return $output
}

# Comprobamos se temos acceso a través de VPN
# Temos que cambiar a IP polo host pasado como parámetro

ping -c1 -W2 10.8.16.181

# Se o comando anterior finaliza con «1», temos que conectar a VPN
if [ $? -eq 1 ] 
then
	msjnc --connect
fi

# En este punto temos acceso a través de VPN

# Temos que comprobar se temos a identidade cargada no axente ssh

ssh-add -l

if [ $? -eq 1 ]
then
	ssh-add $HOME/.ssh/osl_id_rsa
fi

# Temos acceso ao servidor
# Procedemos a realizar a copia dos ficheiros

cd .scp -p cixug-suxi-sug:bera-backup/backup.tar.gz /media/backup/cixug-suxi-sug/$(date +%y%m%d).backup.tar.gz

# Comprobamos o número de copias gardadas

checkcopies
copias=$?

if [ $copias -gt 5 ]; then
	echo "Hai máis de 5 copias... hai que eliminar algunha das máis antigas"
	(( c2d = $copias - 5 ))
	cd /media/backup/cixug-suxi-sug
	rm -i $(ls -1tr | grep .backup.tar.gz | head -n $c2d)
else
	echo "Ainda non se chegou a ter 5 copias"
fi
# Quedar por comprobar as sumas MD5 e evitar erros na descarga
