#!/usr/bin/env bash

CATEGORIES=(
  "CLI Tools:btop,fastfetch,eza,bat,fzf,zoxide,ripgrep,fd,micro,kitty,tmux,stow,wget,curl,rsync,jq,yq"
  "Desktop (KDE):plasma-meta,sddm,xwaylandvideobridge,spectacle,kdeconnect,dolphin,ark,gwenview,okular"
  "Gaming:steam,lutris,heroic-games-launcher,mangohud,gamemode,prismlauncher,wine-staging,winetricks"
  "Dev:git,base-devel,neovim,rustup,docker,docker-compose,nodejs,python,python-pip,lazygit"
  "Security:keepassxc,ufw,gufw,wireguard-tools,veracrypt,firejail,fail2ban"
  "Media:firefox,telegram-desktop,vesktop,qbittorrent,vlc,mpv,obs-studio,flameshot"
  "Fonts & Themes:ttf-jetbrains-mono-nerd,ttf-firacode-nerd,noto-fonts-emoji,noto-fonts-cjk,papirus-icon-theme"
)

select_packages() {
    local category
    local -a package_items=()
    local selected_packages=""

    for category in "${CATEGORIES[@]}"; do
        IFS=':' read -r group_name group_packages <<< "$category"
        IFS=',' read -r -a pkg_list <<< "$group_packages"

        package_items=()
        for pkg in "${pkg_list[@]}"; do
            package_items+=("$pkg" "$pkg" "OFF")
        done

        local choice
        choice=$(whiptail --title "Package selection" \
            --checklist "$group_name" 22 76 12 "${package_items[@]}" \
            3>&1 1>&2 2>&3) || return 1

        if [[ -n "$choice" ]]; then
            for pkg in $choice; do
                selected_packages+="$pkg "
            done
        fi
    done

    printf '%s' "$selected_packages"
}
