<?php

declare(strict_types=1);

use MauticPlugin\ArthaSsoBundle\Controller\SsoController;

return [
    'name'        => 'Artha SSO',
    'description' => 'HMAC SSO hand-off from Artha CRM. Verifies a short-lived signed token and logs the user into Artha Marketing without a password prompt.',
    'version'     => '1.0.0',
    'author'      => 'Artha',
    'routes'      => [
        'public' => [
            'artha_sso' => [
                'path'       => '/artha/sso',
                'controller' => 'MauticPlugin\ArthaSsoBundle\Controller\SsoController::loginAction',
                'method'     => 'GET',
            ],
        ],
        'main'   => [],
        'api'    => [],
    ],
    'services'    => [
        'controllers' => [
            SsoController::class => [
                'class'     => SsoController::class,
                'arguments' => [
                    'doctrine.orm.entity_manager',
                    'security.token_storage',
                ],
            ],
        ],
    ],
];
