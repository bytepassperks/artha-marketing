<?php

declare(strict_types=1);

namespace MauticPlugin\ArthaSsoBundle\Controller;

use Doctrine\ORM\EntityManagerInterface;
use Mautic\UserBundle\Entity\Role;
use Mautic\UserBundle\Entity\User;
use Symfony\Component\HttpFoundation\RedirectResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Security\Core\Authentication\Token\Storage\TokenStorageInterface;
use Symfony\Component\Security\Core\Authentication\Token\UsernamePasswordToken;

/**
 * Accepts a short-lived HMAC token minted by the Artha CRM and logs the matching
 * user into Artha Marketing (Mautic) without a password prompt.
 *
 * Token format: base64url(jsonPayload).base64url(hmacSha256(jsonPayload, secret))
 * Payload:      {"iss":"crm","email":...,"name":...,"iat":...,"exp":...}
 *
 * The Mautic "public" firewall (which serves /artha/sso) and the "main" firewall
 * (which serves /s/*) share the same security context ("mautic"), so a token
 * persisted under the _security_mautic session key is honoured by both.
 */
class SsoController
{
    public function __construct(
        private EntityManagerInterface $em,
        private TokenStorageInterface $tokenStorage,
    ) {
    }

    public function loginAction(Request $request): Response
    {
        $raw    = (string) $request->query->get('artha_sso', '');
        $secret = $this->secret();

        if ('' === $raw || '' === $secret) {
            return new Response('Artha SSO is not configured.', Response::HTTP_FORBIDDEN);
        }

        $payload = $this->verify($raw, $secret);
        if (null === $payload) {
            return new Response('Invalid or expired Artha SSO token.', Response::HTTP_FORBIDDEN);
        }

        $email = isset($payload['email']) ? trim((string) $payload['email']) : '';
        if ('' === $email || false === filter_var($email, FILTER_VALIDATE_EMAIL)) {
            return new Response('Invalid Artha SSO payload.', Response::HTTP_FORBIDDEN);
        }

        $name = isset($payload['name']) ? trim((string) $payload['name']) : $email;

        /** @var \Doctrine\ORM\EntityRepository<User> $userRepo */
        $userRepo = $this->em->getRepository(User::class);
        $user     = $userRepo->findOneBy(['email' => $email]);

        if (!$user instanceof User) {
            $user = $this->provision($email, $name);
        }

        $token = new UsernamePasswordToken($user, 'main', $user->getRoles());
        $this->tokenStorage->setToken($token);

        $session = $request->getSession();
        $session->set('_security_mautic', serialize($token));
        $session->save();

        return new RedirectResponse('/s/dashboard');
    }

    private function secret(): string
    {
        $secret = getenv('ARTHA_SSO_SECRET');
        if (false === $secret || '' === $secret) {
            $secret = $_SERVER['ARTHA_SSO_SECRET'] ?? $_ENV['ARTHA_SSO_SECRET'] ?? '';
        }

        return (string) $secret;
    }

    /**
     * @return array<string, mixed>|null
     */
    private function verify(string $raw, string $secret): ?array
    {
        $parts = explode('.', $raw);
        if (2 !== count($parts)) {
            return null;
        }

        [$encodedPayload, $signature] = $parts;

        $expected = $this->base64UrlEncode(hash_hmac('sha256', $encodedPayload, $secret, true));
        if (!hash_equals($expected, $signature)) {
            return null;
        }

        $data = json_decode($this->base64UrlDecode($encodedPayload), true);
        if (!is_array($data)) {
            return null;
        }

        if (('crm' !== ($data['iss'] ?? null))) {
            return null;
        }

        $exp = isset($data['exp']) ? (int) $data['exp'] : 0;
        if ($exp < time()) {
            return null;
        }

        return $data;
    }

    private function provision(string $email, string $name): User
    {
        $parts = preg_split('/\s+/', $name, 2) ?: [];
        $first = ('' !== ($parts[0] ?? '')) ? $parts[0] : 'Artha';
        $last  = $parts[1] ?? 'User';

        /** @var \Doctrine\ORM\EntityRepository<Role> $roleRepo */
        $roleRepo = $this->em->getRepository(Role::class);
        $role     = $roleRepo->findOneBy(['isAdmin' => true]) ?? $roleRepo->findOneBy([]);

        if (!$role instanceof Role) {
            $role = new Role();
            $role->setName('Administrator');
            $role->setIsAdmin(true);
            $this->em->persist($role);
        }

        $user = new User();
        $user->setEmail($email);
        $user->setUsername($this->uniqueUsername($email));
        $user->setFirstName($first);
        $user->setLastName($last);
        $user->setRole($role);
        $user->setPassword(bin2hex(random_bytes(24)));
        $user->setIsPublished(true);

        $this->em->persist($user);
        $this->em->flush();

        return $user;
    }

    private function uniqueUsername(string $email): string
    {
        $base = strstr($email, '@', true);
        $base = preg_replace('/[^a-zA-Z0-9._-]/', '', (string) ($base ?: $email));
        $base = ('' !== (string) $base) ? (string) $base : 'user';

        /** @var \Doctrine\ORM\EntityRepository<User> $repo */
        $repo      = $this->em->getRepository(User::class);
        $candidate = $base;
        $i         = 1;

        while (null !== $repo->findOneBy(['username' => $candidate])) {
            $candidate = $base.$i;
            ++$i;
        }

        return $candidate;
    }

    private function base64UrlEncode(string $data): string
    {
        return rtrim(strtr(base64_encode($data), '+/', '-_'), '=');
    }

    private function base64UrlDecode(string $data): string
    {
        return (string) base64_decode(strtr($data, '-_', '+/'), true);
    }
}
