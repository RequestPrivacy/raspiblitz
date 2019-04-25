#!/bin/bash
echo "Starting the main menu ..."

# CONFIGFILE - configuration of RaspiBlitz
configFile="/mnt/hdd/raspiblitz.conf"

# INFOFILE - state data from bootstrap
infoFile="/home/admin/raspiblitz.info"

# check if HDD is connected
hddExists=$(lsblk | grep -c sda1)
if [ ${hddExists} -eq 0 ]; then

  # check if there is maybe a HDD but woth no partitions
  noPartition=$(lsblk | grep -c sda)
  if [ ${noPartition} -eq 1 ]; then
    echo "***********************************************************"
    echo "WARNING: HDD HAS NO PARTITIONS"
    echo "***********************************************************"
    echo "Press ENTER to create a Partition - or CTRL+C to abort"
    read key
    echo "Creating Partition ..."
    sudo parted -s /dev/sda unit s mkpart primary `sudo parted /dev/sda unit s print free | grep 'Free Space' | tail -n 1`
    echo "DONE."
    sleep 3
  else 
    echo "***********************************************************"
    echo "WARNING: NO HDD FOUND -> Shutdown, connect HDD and restart."
    echo "***********************************************************"
    exit
  fi
fi

# check data from _bootstrap.sh that was running on device setup
bootstrapInfoExists=$(ls $infoFile | grep -c '.info')
if [ ${bootstrapInfoExists} -eq 0 ]; then
  echo "***********************************************************"
  echo "WARNING: NO raspiblitz.info FOUND -> bootstrap not running?"
  echo "***********************************************************"
  exit
fi

# load the data from the info file (will get produced on every startup)
source ${infoFile}

if [ "${state}" = "recovering" ]; then
  echo "***********************************************************"
  echo "WARNING: bootstrap still updating - close SSH, login later"
  echo "To monitor progress --> tail -n1000 -f raspiblitz.log"
  echo "***********************************************************"
  exit
fi

# signal that after bootstrap recover user dialog is needed
if [ "${state}" = "recovered" ]; then
  echo "System recovered - needs final user settings"
  /home/admin/20recoverDialog.sh 
  exit 1
fi

# signal that a reindex was triggered
if [ "${state}" = "reindex" ]; then
  echo "Re-Index in progress ... start monitoring:"
  /home/admin/config.scripts/network.reindex.sh
  exit 1
fi

# singal that torrent is in re-download
if [ "${state}" = "retorrent" ]; then
  echo "Re-Index in progress ... start monitoring:"
  /home/admin/50torrentHDD.sh
  sudo sed -i "s/^state=.*/state=repair/g" /home/admin/raspiblitz.info
  /home/admin/00raspiblitz.sh
  exit
fi

# if pre-sync is running - stop it - before continue
if [ "${state}" = "presync" ]; then
  # stopping the pre-sync
  echo ""
  # analyse if blockchain was detected broken by pre-sync
  blockchainBroken=$(sudo tail /mnt/hdd/bitcoin/debug.log | grep -c "Please restart with -reindex or -reindex-chainstate to recover.")
  if [ ${blockchainBroken} -eq 1 ]; then
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "Detected corrupted blockchain on pre-sync !"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "Deleting blockchain data ..."
    echo "(needs to get downloaded fresh during setup)"
    sudo rm -f -r /mnt/hdd/bitcoin
  else
    echo "********************************************"
    echo "Stopping pre-sync ... pls wait (up to 1min)"
    echo "********************************************"
    sudo -u root bitcoin-cli -conf=/home/admin/assets/bitcoin.conf stop
    echo "bitcoind called to stop .."
    sleep 50
  fi

  # unmount the temporary mount
  echo "Unmount HDD .."
  sudo umount -l /mnt/hdd
  sleep 3

  # update info file
  state=waitsetup
  sudo sed -i "s/^state=.*/state=waitsetup/g" $infoFile
  sudo sed -i "s/^message=.*/message='Pre-Sync Stopped'/g" $infoFile
fi

# if state=ready -> setup is done or started
if [ "${state}" = "ready" ]; then
  configExists=$(ls ${configFile} | grep -c '.conf')
  if [ ${configExists} -eq 1 ]; then
    echo "loading config data"
    source ${configFile}
  else
    echo "setup still in progress - setupStep(${setupStep})"
  fi
fi

## default menu settings
# to fit the main menu without scrolling: 
HEIGHT=13
WIDTH=64
CHOICE_HEIGHT=6
BACKTITLE="RaspiBlitz"
TITLE=""
MENU="Choose one of the following options:"
OPTIONS=()

# check if RTL web interface is installed
runningRTL=$(sudo ls /etc/systemd/system/RTL.service 2>/dev/null | grep -c 'RTL.service')

# function to use later
waitUntilChainNetworkIsReady()
{
    echo "checking ${network}d - please wait .."
    echo "can take longer if device was off or first time"
    while :
    do
      
      # check for error on network
      sudo -u bitcoin ${network}-cli -datadir=/home/bitcoin/.${network} getblockchaininfo 1>/dev/null 2>error.tmp
      clienterror=`cat error.tmp`
      rm error.tmp

      # check for missing blockchain data
      minSize=250000000000
      if [ "${network}" = "litecoin" ]; then
        minSize=20000000000
      fi
      blockchainsize=$(sudo du -shbc /mnt/hdd/${network} | head -n1 | awk '{print $1;}')
      if [ ${#blockchainsize} -gt 0 ]; then
        if [ ${blockchainsize} -lt ${minSize} ]; then
          echo "blockchainsize(${blockchainsize})"
          echo "Missing Blockchain Data (<${minSize}) ..."
          clienterror="missing blockchain"
          sleep 3
        fi
      fi

      if [ ${#clienterror} -gt 0 ]; then

        # analyse LOGS for possible reindex
        reindex=$(sudo cat /mnt/hdd/${network}/debug.log | grep -c 'Please restart with -reindex or -reindex-chainstate to recover')
        if [ ${reindex} -gt 0 ] || [ "${clienterror}" = "missing blockchain" ]; then
          echo "!! DETECTED NEED FOR RE-INDEX in debug.log ... starting repair options."
          sudo sed -i "s/^state=.*/state=repair/g" /home/admin/raspiblitz.info
          sleep 3

          dialog --backtitle "RaspiBlitz - Repair Script" --msgbox "Your blockchain data needs to be repaired.
This can be due to power problems or a failing HDD.
Please check the FAQ on RaspiBlitz Github
'My blockchain data is corrupted - what can I do?'
https://github.com/rootzoll/raspiblitz/blob/master/FAQ.md

The RaspiBlitz will now try to help you on with the repair.
To run a BACKUP of funds & channels first is recommended.
" 13 65

          clear
          # Basic Options
          OPTIONS=(TORRENT "Redownload Prepared Torrent (DEFAULT)" \
                   COPY "Copy from another Computer (SKILLED)" \
                   REINDEX "Resync thru ${network}d (TAKES VERY VERY LONG)" \
                   BACKUP "Run Backup LND data first (optional)"
          )

          CHOICE=$(dialog --backtitle "RaspiBlitz - Repair Script" --clear --title "Repair Blockchain Data" --menu "Choose a repair/recovery option:" 11 60 6 "${OPTIONS[@]}" 2>&1 >/dev/tty)

          clear
          if [ "${CHOICE}" = "TORRENT" ]; then
            echo "Starting TORRENT ..."
            sudo sed -i "s/^state=.*/state=retorrent/g" /home/admin/raspiblitz.info
            /home/admin/50torrentHDD.sh
            sudo sed -i "s/^state=.*/state=repair/g" /home/admin/raspiblitz.info
            /home/admin/00raspiblitz.sh
            exit

          elif [ "${CHOICE}" = "COPY" ]; then
            echo "Starting COPY ..."
            sudo sed -i "s/^state=.*/state=recopy/g" /home/admin/raspiblitz.info
            /home/admin/50copyHDD.sh
            sudo sed -i "s/^state=.*/state=repair/g" /home/admin/raspiblitz.info
            /home/admin/00raspiblitz.sh
            exit

          elif [ "${CHOICE}" = "REINDEX" ]; then
            echo "Starting REINDEX ..."
            sudo /home/admin/config.scripts/network.reindex.sh
            exit

          elif [ "${CHOICE}" = "BACKUP" ]; then
            sudo /home/admin/config.scripts/lnd.rescue.sh backup
            echo "PRESS ENTER to return to menu."
            read key
            /home/admin/00raspiblitz.sh
            exit

          else
            echo "CANCEL"
            exit
          fi

        fi

        # let 80scanLND script to the info to use
        /home/admin/80scanLND.sh
        if [ $? -gt 0 ]; then
          echo "${network} error: ${clienterror}"
          exit 0
        fi

      else
        locked=$(sudo -u bitcoin /usr/local/bin/lncli --chain=${network} --network=${chain}net getinfo 2>&1 | grep -c unlock)
        if [ ${locked} -gt 0 ]; then
          uptime=$(awk '{printf("%d\n",$1 + 0.5)}' /proc/uptime)
          if [ "${autoUnlock}" == "on" ] && [ ${uptime} -lt 300 ]; then
            # give autounlock 5 min after startup to react
            sleep 1
          else
            /home/admin/AAunlockLND.sh
            echo "Starting up Wallet ..."
            sleep 8
            echo "Please Wait ... update to next screen can be slow"
          fi
        fi
        lndSynced=$(sudo -u bitcoin /usr/local/bin/lncli --chain=${network} --network=${chain}net getinfo 2>/dev/null | jq -r '.synced_to_chain' | grep -c true)
        if [ ${lndSynced} -eq 0 ]; then
          /home/admin/80scanLND.sh
          if [ $? -gt 0 ]; then
            exit 0
          fi
        else
          # everything is ready - return from loop
          return
        fi
      fi
      sleep 5
    done
}

if [ ${#setupStep} -eq 0 ]; then
  echo "WARN: no setup step found in raspiblitz.info"
  setupStep=0
fi
if [ ${setupStep} -eq 0 ]; then

  # check data from boostrap
  # TODO: when olddata --> CLEAN OR MANUAL-UPDATE-INFO
  if [ "${state}" = "olddata" ]; then

    # old data setup
    BACKTITLE="RaspiBlitz - Manual Update"
    TITLE="⚡ Found old RaspiBlitz Data on HDD ⚡"
    MENU="\n         ATTENTION: OLD DATA COULD CONTAIN FUNDS\n"
    OPTIONS+=(MANUAL "read how to recover your old funds" \
              DELETE "erase old data, keep blockchain, reboot" )
    HEIGHT=11

  else

    # show hardware test
    /home/admin/05hardwareTest.sh

    # start setup
    BACKTITLE="RaspiBlitz - Setup"
    TITLE="⚡ Welcome to your RaspiBlitz ⚡"
    MENU="\nChoose how you want to setup your RaspiBlitz: \n "
    OPTIONS+=(BITCOIN "Setup BITCOIN and Lightning (DEFAULT)" \
              LITECOIN "Setup LITECOIN and Lightning (EXPERIMENTAL)" )
    HEIGHT=11

  fi

elif [ ${setupStep} -lt 100 ]; then

    # see function above
    if [ ${setupStep} -gt 59 ]; then
      waitUntilChainNetworkIsReady
    fi

    # continue setup
    BACKTITLE="${hostname} / ${network} / ${chain}"
    TITLE="⚡ Welcome to your RaspiBlitz ⚡"
    MENU="\nThe setup process is not finished yet: \n "
    OPTIONS+=(CONTINUE "Continue Setup of your RaspiBlitz")
    HEIGHT=10

else

  # when all is setup - forward to main menu
  waitUntilChainNetworkIsReady
  /home/admin/00mainMenu.sh
  exit 0

fi

CHOICE=$(dialog --clear \
                --backtitle "$BACKTITLE" \
                --title "$TITLE" \
                --menu "$MENU" \
                $HEIGHT $WIDTH $CHOICE_HEIGHT \
                "${OPTIONS[@]}" \
                2>&1 >/dev/tty)

clear
case $CHOICE in
        CLOSE)
            exit 1;
            ;;
        BITCOIN)
            sed -i "s/^network=.*/network=bitcoin/g" ${infoFile}
            sed -i "s/^chain=.*/chain=main/g" ${infoFile}
            /home/admin/10setupBlitz.sh
            exit 1;
            ;;
        LITECOIN)
            sed -i "s/^network=.*/network=litecoin/g" ${infoFile}
            sed -i "s/^chain=.*/chain=main/g" ${infoFile}
            /home/admin/10setupBlitz.sh
            exit 1;
            ;;
        CONTINUE)
            /home/admin/10setupBlitz.sh
            exit 1;
            ;;
        OFF)
            echo ""
            echo "LCD turns white when shutdown complete."
            echo "Then wait 5 seconds and disconnect power."
            echo "-----------------------------------------------"
            echo "stop lnd - please wait .."
            sudo systemctl stop lnd
            echo "stop ${network}d (1) - please wait .."
            sudo -u bitcoin ${network}-cli stop
            sleep 10
            echo "stop ${network}d (2) - please wait .."
            sudo systemctl stop ${network}d
            sleep 3
            sync
            echo "starting shutdown ..."
            sudo shutdown now
            exit 0
            ;;
        MANUAL)
            echo "************************************************************************************"
            echo "PLEASE go to RaspiBlitz FAQ:"
            echo "https://github.com/rootzoll/raspiblitz"
            echo "And check: How can I recover my coins from a failing RaspiBlitz?"
            echo "************************************************************************************"
            exit 0
            ;;
        DELETE)
            sudo /home/admin/XXcleanHDD.sh
            sudo shutdown -r now
            exit 0
            ;;   
        X)
            lncli -h
            echo "OK you now on the command line."
            echo "You can return to the main menu with the command:"
            echo "raspiblitz"
            ;;
        R)
            /home/admin/00raspiblitz.sh
            ;;
        U) # unlock
            /home/admin/AAunlockLND.sh
            /home/admin/00raspiblitz.sh
            ;;
esac
