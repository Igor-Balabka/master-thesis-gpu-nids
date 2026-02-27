#ifndef UTILS_H
#define UTILS_H

#include "ac.h" // Nécessaire car on utilise le type AC_Machine

/**
 * Charge un fichier complet en mémoire.
 * @param filename Chemin du fichier à lire.
 * @param length Pointeur pour stocker la taille du fichier lu.
 * @return Un pointeur vers le buffer de données (à libérer avec free()).
 */
char* load_file(const char* filename, long* length);

/**
 * Lit un fichier de règles et les ajoute à l'automate.
 * @param ac Pointeur vers la structure de l'automate.
 * @param filename Chemin du fichier contenant les patterns (1 par ligne).
 */
void load_patterns(AC_Machine* ac, const char* filename);

#endif