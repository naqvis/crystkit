import { createRouter, createWebHashHistory } from 'vue-router'

// Lazy-load all panels so the initial bundle stays small
const Dashboard = () => import('./views/Dashboard.vue')
const Terminal = () => import('./views/Terminal.vue')
const HttpClient = () => import('./views/HttpClient.vue')
const Snippets = () => import('./views/Snippets.vue')
const Notes = () => import('./views/Notes.vue')
const Explorer = () => import('./views/Explorer.vue')
const Settings = () => import('./views/Settings.vue')

export const router = createRouter({
    history: createWebHashHistory(),
    routes: [
        { path: '/', name: 'dashboard', component: Dashboard },
        { path: '/terminal', name: 'terminal', component: Terminal },
        { path: '/http', name: 'http', component: HttpClient },
        { path: '/snippets', name: 'snippets', component: Snippets },
        { path: '/notes', name: 'notes', component: Notes },
        { path: '/explorer', name: 'explorer', component: Explorer },
        { path: '/settings', name: 'settings', component: Settings },
    ],
})
