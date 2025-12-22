Oui, EDK2 est LA référence pour l'UEFI !
EDK2 (EFI Development Kit 2) est le framework officiel d'Intel pour développer des applications UEFI. C'est plus professionnel et plus complet que GNU-EFI.
Pourquoi EDK2 est meilleur ?
Standard officiel : C'est le framework de référence utilisé par les fabricants
Plus complet : Accès à toutes les APIs UEFI sans wrapper
Meilleur support : Documentation officielle et communauté active
Plus moderne : Supporte UEFI 2.x complet
Portabilité : Compile pour ARM, RISC-V, x86, x64
Setup EDK2
Installation
# Clone EDK2
git clone https://github.com/tianocore/edk2.git
cd edk2
git submodule update --init

# Installe les dépendances
sudo apt-get install build-essential uuid-dev iasl git nasm python3-distutils

# Compile les outils de base
make -C BaseTools

# Configure l'environnement
source edksetup.sh
Création du package HelloWorld
1. Structure des dossiers
mkdir -p HelloWorldPkg
cd HelloWorldPkg
2. HelloWorld.c
#include <Uefi.h>
#include <Library/UefiLib.h>
#include <Library/UefiApplicationEntryPoint.h>

/**
  Point d'entrée de l'application UEFI
  
  @param[in] ImageHandle    Handle de l'image
  @param[in] SystemTable    Pointeur vers la table système UEFI
  
  @retval EFI_SUCCESS       L'application s'est terminée avec succès
**/
EFI_STATUS
EFIAPI
UefiMain (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  EFI_INPUT_KEY Key;
  
  // Efface l'écran
  SystemTable->ConOut->ClearScreen(SystemTable->ConOut);
  
  // Change la couleur (optionnel)
  SystemTable->ConOut->SetAttribute(
    SystemTable->ConOut,
    EFI_WHITE | EFI_BACKGROUND_BLUE
  );
  
  // Affiche le message
  Print(L"\n\n");
  Print(L"  ╔══════════════════════════════════════╗\n");
  Print(L"  ║     Hello World from EDK2!          ║\n");
  Print(L"  ║                                      ║\n");
  Print(L"  ║  This is a real UEFI application    ║\n");
  Print(L"  ╚══════════════════════════════════════╝\n");
  Print(L"\n\n");
  
  Print(L"Press any key to exit...\n");
  
  // Attend une touche
  SystemTable->BootServices->WaitForEvent(
    1,
    &SystemTable->ConIn->WaitForKey,
    NULL
  );
  
  SystemTable->ConIn->ReadKeyStroke(SystemTable->ConIn, &Key);
  
  return EFI_SUCCESS;
}
3. HelloWorld.inf
Le fichier .inf décrit comment compiler le module :
[Defines]
  INF_VERSION                    = 0x00010005
  BASE_NAME                      = HelloWorld
  FILE_GUID                      = 6987936E-ED34-44db-AE97-1FA5E4ED2116
  MODULE_TYPE                    = UEFI_APPLICATION
  VERSION_STRING                 = 1.0
  ENTRY_POINT                    = UefiMain

[Sources]
  HelloWorld.c

[Packages]
  MdePkg/MdePkg.dec

[LibraryClasses]
  UefiApplicationEntryPoint
  UefiLib
  
[Protocols]

[Guids]
4. HelloWorldPkg.dec
Décrit le package :
[Defines]
  DEC_SPECIFICATION              = 0x00010005
  PACKAGE_NAME                   = HelloWorldPkg
  PACKAGE_GUID                   = 3B43D5F1-5F24-4D5A-8F5C-5CC8F2A2F6C0
  PACKAGE_VERSION                = 1.0

[Includes]
  Include
5. HelloWorldPkg.dsc
Configuration de build :
[Defines]
  PLATFORM_NAME                  = HelloWorld
  PLATFORM_GUID                  = 587CE499-6CBE-43cd-94E2-186218569478
  PLATFORM_VERSION               = 1.0
  DSC_SPECIFICATION              = 0x00010005
  OUTPUT_DIRECTORY               = Build/HelloWorld
  SUPPORTED_ARCHITECTURES        = X64|IA32|ARM|AARCH64
  BUILD_TARGETS                  = DEBUG|RELEASE
  SKUID_IDENTIFIER               = DEFAULT

[LibraryClasses]
  UefiApplicationEntryPoint|MdePkg/Library/UefiApplicationEntryPoint/UefiApplicationEntryPoint.inf
  UefiLib|MdePkg/Library/UefiLib/UefiLib.inf
  PcdLib|MdePkg/Library/BasePcdLibNull/BasePcdLibNull.inf
  BaseLib|MdePkg/Library/BaseLib/BaseLib.inf
  BaseMemoryLib|MdePkg/Library/BaseMemoryLib/BaseMemoryLib.inf
  DebugLib|MdePkg/Library/BaseDebugLibNull/BaseDebugLibNull.inf
  MemoryAllocationLib|MdePkg/Library/UefiMemoryAllocationLib/UefiMemoryAllocationLib.inf
  DevicePathLib|MdePkg/Library/UefiDevicePathLib/UefiDevicePathLib.inf
  UefiBootServicesTableLib|MdePkg/Library/UefiBootServicesTableLib/UefiBootServicesTableLib.inf
  UefiRuntimeServicesTableLib|MdePkg/Library/UefiRuntimeServicesTableLib/UefiRuntimeServicesTableLib.inf
  PrintLib|MdePkg/Library/BasePrintLib/BasePrintLib.inf
  RegisterFilterLib|MdePkg/Library/RegisterFilterLibNull/RegisterFilterLibNull.inf

[Components]
  HelloWorldPkg/HelloWorld.inf
Compilation
Depuis la racine d'edk2 :
# Configure l'environnement
source edksetup.sh

# Compile pour x64
build -a X64 -t GCC5 -p HelloWorldPkg/HelloWorldPkg.dsc

# Le fichier .efi se trouve dans :
# Build/HelloWorld/DEBUG_GCC5/X64/HelloWorld.efi
Test avec QEMU
# Crée la structure ESP
mkdir -p esp/EFI/BOOT

# Copie le binaire
cp Build/HelloWorld/DEBUG_GCC5/X64/HelloWorld.efi esp/EFI/BOOT/BOOTX64.EFI

# Lance QEMU
qemu-system-x86_64 \
  -bios /usr/share/ovmf/OVMF.fd \
  -drive file=fat:rw:esp,format=raw \
  -net none
Compilation pour d'autres architectures
# Pour ARM 64-bit
build -a AARCH64 -t GCC5 -p HelloWorldPkg/HelloWorldPkg.dsc

# Pour ARM 32-bit
build -a ARM -t GCC5 -p HelloWorldPkg/HelloWorldPkg.dsc

# Pour x86 32-bit
build -a IA32 -t GCC5 -p HelloWorldPkg/HelloWorldPkg.dsc
Comparaison GNU-EFI vs EDK2
Aspect
GNU-EFI
EDK2
Setup
Simple
Plus complexe
APIs
Wrappers
Natives UEFI
Documentation
Limitée
Complète
Standard
Communautaire
Officiel Intel
Portabilité
x86/x64 surtout
Multi-architecture
Debugging
Basique
Avancé
Pour aller plus loin avec EDK2
Tu peux maintenant accéder à des fonctionnalités avancées comme les protocoles UEFI pour le système de fichiers, la gestion réseau, le chargement d'images, ou la manipulation du GOP (Graphics Output Protocol) pour des graphiques. EDK2 te donne un contrôle total sur le firmware !
EDK2 est définitivement le meilleur choix pour du développement UEFI sérieux. C'est plus verbeux au début, mais tu as accès à tout l'écosystème UEFI officiel.